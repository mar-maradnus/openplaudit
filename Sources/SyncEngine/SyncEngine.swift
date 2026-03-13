/// Sync orchestrator — download, decode, transcribe pipeline.
///
/// Ported from Python CLI `src/plaude/sync.py`.

import Foundation
import AVFoundation
import BLEKit
import AudioKit
import TranscriptionKit
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "sync")

/// Observable sync engine for the menubar app.
@MainActor
public final class SyncEngine: ObservableObject {
    @Published public var status: SyncStatus = .idle
    @Published public var recentRecordings: [RecentRecording] = []
    @Published public var isConnected = false
    @Published public var progress: SyncProgress?

    public let state: SessionState
    public var config: AppConfig

    private var client: PlaudClient?
    private var autoSyncTimer: Timer?
    private var syncTask: Task<Int, Error>?
    private lazy var transcriber = Transcriber(model: config.transcription.model)

    public init(config: AppConfig = AppConfig(), statePath: URL = defaultStatePath) {
        self.config = config
        self.state = SessionState(path: statePath)
        rebuildRecentRecordings()
    }

    // MARK: - Auto-Sync

    /// Start periodic auto-sync at the configured interval (minutes).
    public func startAutoSync(intervalMinutes: Int = 30) {
        stopAutoSync()
        let interval = TimeInterval(max(intervalMinutes, 1) * 60)
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.startSync()
            }
        }
    }

    /// Start a sync. If already syncing, does nothing.
    public func startSync() {
        guard syncTask == nil else { return }
        syncTask = Task {
            defer { syncTask = nil }
            do {
                return try await runSync()
            } catch is CancellationError {
                return 0
            } catch {
                status = .error(error.localizedDescription)
                throw error
            }
        }
    }

    /// Cancel an in-progress sync.
    public func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        status = .idle
        log.info("Sync cancelled by user")
    }

    public func stopAutoSync() {
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
    }

    // MARK: - Sync Status

    public enum SyncStatus: Equatable {
        case idle
        case connecting
        case syncing(current: Int, total: Int)
        case error(String)
    }

    public struct SyncProgress: Equatable {
        public let bytesReceived: Int
        public let bytesExpected: Int
        public let percentage: Double
    }

    public struct RecentRecording: Identifiable, Equatable {
        public let id: UInt32  // session_id
        public let date: Date
        public let durationSeconds: Double?
        public let filename: String
    }

    // MARK: - Sync

    /// Full sync pipeline. Returns count of newly completed recordings.
    public func runSync() async throws -> Int {
        guard !config.device.address.isEmpty, !config.device.token.isEmpty else {
            status = .error("Device not configured")
            throw SyncError.notConfigured
        }

        let dirs = getOutputDirs(config)
        let fm = FileManager.default
        try fm.createDirectory(at: dirs.audio, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirs.transcripts, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirs.raw, withIntermediateDirectories: true)

        status = .connecting
        log.info("Starting sync...")
        let client = PlaudClient(address: config.device.address, token: config.device.token)
        self.client = client

        defer {
            Task { await client.disconnect() }
            self.client = nil
            self.isConnected = false
        }

        do {
            try await client.connect()
        } catch {
            status = .error("Connection failed: \(error.localizedDescription)")
            throw error
        }
        isConnected = true

        try Task.checkCancellation()

        do {
            guard try await client.handshake() else {
                status = .error("Handshake failed — check token or ensure device is not recording")
                throw SyncError.handshakeFailed
            }
        } catch let error as SyncError {
            throw error
        } catch {
            status = .error("Handshake failed: \(error.localizedDescription)")
            throw error
        }

        try await client.timeSync()
        try Task.checkCancellation()

        let sessions = try await client.getSessions()
        let pending = sessions.filter { !state.isComplete($0.sessionID) }
        guard !pending.isEmpty else {
            log.info("No pending sessions")
            status = .idle
            return 0
        }

        log.info("\(pending.count) session(s) to sync")
        var completedCount = 0
        var completedNames: [String] = []

        for (index, session) in pending.enumerated() {
            try Task.checkCancellation()

            status = .syncing(current: index + 1, total: pending.count)
            let sid = session.sessionID
            let fname = sessionFilename(sid)

            do {
                let rawFilePath = dirs.raw.appendingPathComponent("\(fname).opus")
                let wavPath = dirs.audio.appendingPathComponent("\(fname).wav")

                // Phase 1+2: Download and Decode
                let hasRawFile = fm.fileExists(atPath: rawFilePath.path)
                let needsFresh = state.needsDownload(sid) ||
                    (state.needsDecode(sid) && !hasRawFile)

                if needsFresh {
                    log.info("Downloading session \(sid)")
                    let rawData = try await downloadFile(
                        client: client,
                        sessionID: sid,
                        fileSize: session.fileSize,
                        progress: { [weak self] current, expected, pct in
                            Task { @MainActor in
                                self?.progress = SyncProgress(
                                    bytesReceived: current,
                                    bytesExpected: expected,
                                    percentage: pct
                                )
                            }
                        }
                    )

                    try Task.checkCancellation()

                    if config.sync.keepRaw {
                        try rawData.write(to: rawFilePath, options: .atomic)
                    }

                    log.info("Decoding session \(sid)")
                    let pcm = try await Task.detached {
                        try decodeOpusRaw(rawData)
                    }.value
                    try await Task.detached {
                        try saveWAV(pcm, to: wavPath)
                    }.value

                    state.markDownloaded(sid)
                    state.markDecoded(sid)
                    try state.saveAtomically()

                    let duration = Self.wavDuration(wavPath)
                        ?? Double(pcm.count) / (16000.0 * 2.0)
                    addRecentRecording(sid: sid, duration: duration, filename: fname)

                } else if state.needsDecode(sid) {
                    let url = rawFilePath
                    let pcm = try await Task.detached {
                        let rawData = try Data(contentsOf: url)
                        return try decodeOpusRaw(rawData)
                    }.value
                    try await Task.detached {
                        try saveWAV(pcm, to: wavPath)
                    }.value

                    state.markDecoded(sid)
                    try state.saveAtomically()
                }

                try Task.checkCancellation()

                // Phase 3: Transcription (off main actor)
                if state.needsTranscription(sid) {
                    log.info("Transcribing session \(sid)")
                    let t = self.transcriber
                    let lang = config.transcription.language
                    let result = try await Task.detached {
                        try await t.transcribe(wavPath: wavPath, language: lang)
                    }.value

                    let jsonPath = dirs.transcripts.appendingPathComponent("\(fname).json")
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(result).write(to: jsonPath, options: .atomic)

                    state.markTranscribed(sid)
                    try state.saveAtomically()

                    if config.sync.autoDeleteLocalAudio {
                        try? fm.removeItem(at: wavPath)
                    }
                }

                completedCount += 1
                completedNames.append(fname)
                log.info("Session \(sid) complete")

            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("Session \(sid) failed: \(error.localizedDescription, privacy: .public)")
                state.markFailed(sid, reason: "\(type(of: error)): \(error.localizedDescription)")
                try? state.saveAtomically()
            }

            progress = nil
        }

        // Batch notification: one summary instead of per-session
        if config.notifications.enabled && completedCount > 0 {
            let body: String
            if completedCount == 1 {
                body = "Recording synced: \(completedNames.first ?? "")"
            } else {
                body = "\(completedCount) recordings synced"
            }
            sendNotification(title: "OpenPlaudit", body: body)
        }

        log.info("Sync complete: \(completedCount) recording(s)")
        status = .idle
        return completedCount
    }

    /// Get exact WAV duration via AVAudioFile; returns nil on failure.
    static func wavDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Config Persistence

    /// Save config to TOML (without token) and token to Keychain.
    public func persistConfig() {
        try? saveConfigWithKeychain(config)
    }

    // MARK: - Helpers

    private func addRecentRecording(sid: UInt32, duration: Double?, filename: String) {
        let recording = RecentRecording(
            id: sid,
            date: Date(timeIntervalSince1970: TimeInterval(sid)),
            durationSeconds: duration,
            filename: filename
        )
        recentRecordings.insert(recording, at: 0)
        if recentRecordings.count > 10 { recentRecordings.removeLast() }
    }

    /// Rebuild recent recordings from state.json and audio directory on launch.
    private func rebuildRecentRecordings() {
        let dirs = getOutputDirs(config)
        var recordings: [RecentRecording] = []

        for (key, entry) in state.allEntries {
            guard entry["decoded_at"] != nil || entry["transcribed_at"] != nil,
                  let sid = UInt32(key) else { continue }

            let fname = sessionFilename(sid)
            let wavPath = dirs.audio.appendingPathComponent("\(fname).wav")

            let duration = Self.wavDuration(wavPath)

            recordings.append(RecentRecording(
                id: sid,
                date: Date(timeIntervalSince1970: TimeInterval(sid)),
                durationSeconds: duration,
                filename: fname
            ))
        }

        recentRecordings = Array(recordings.sorted { $0.date > $1.date }.prefix(10))
    }
}

// MARK: - Errors

public enum SyncError: Error, LocalizedError {
    case notConfigured
    case handshakeFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Device address and token must be configured"
        case .handshakeFailed: return "Handshake failed — check token or ensure device is not recording"
        }
    }
}

// MARK: - Filename Helpers

/// Convert session_id (unix timestamp) to a timezone-stable filename stem.
public func sessionFilename(_ sessionID: UInt32) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(sessionID))
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd_HHmmss"
    fmt.timeZone = TimeZone(identifier: "UTC")
    return fmt.string(from: date) + "_UTC"
}

/// Format session_id as local time for display.
public func formatLocalTime(_ sessionID: UInt32) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(sessionID))
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return fmt.string(from: date)
}
