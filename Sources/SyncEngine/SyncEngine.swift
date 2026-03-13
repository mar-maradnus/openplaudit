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

    /// Start a sync. Blocked while syncing or cancelling.
    public func startSync() {
        guard syncTask == nil else { return }
        syncTask = Task {
            defer {
                syncTask = nil
                if status == .cancelling { status = .idle }
            }
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

    /// Cancel an in-progress sync. Sets status to `.cancelling` until the
    /// task fully unwinds; `startSync()` is blocked until `syncTask` is nil.
    public func cancelSync() {
        guard syncTask != nil else { return }
        status = .cancelling
        syncTask?.cancel()
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
        case cancelling
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
        public let transcriptPreview: String?
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
        } catch let error as BLEError {
            status = .error(Self.remediation(for: error))
            throw error
        } catch {
            status = .error("Connection failed: \(error.localizedDescription)")
            throw error
        }
        isConnected = true
        if let name = await client.deviceName, !name.isEmpty {
            config.device.name = name
        }

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
        var lastTranscriptPreview: String?

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

                    if config.notifications.showPreview {
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            lastTranscriptPreview = String(text.prefix(100))
                        }
                    }

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
            let subtitle = lastTranscriptPreview ?? ""
            sendNotification(title: "OpenPlaudit", body: body, subtitle: subtitle)
        }

        log.info("Sync complete: \(completedCount) recording(s)")
        status = .idle
        return completedCount
    }

    /// User-facing remediation message for BLE errors.
    private static func remediation(for error: BLEError) -> String {
        switch error {
        case .bluetoothOff:
            return "Bluetooth is off — turn it on in System Settings"
        case .bluetoothUnauthorized:
            return "Bluetooth permission denied — grant access in System Settings > Privacy > Bluetooth"
        case .deviceNotFound:
            return "Device not found — ensure PLAUD Note is nearby, powered on, and not connected to another app"
        case .connectionFailed:
            return "Connection failed — try moving closer to the device and ensure it is not recording"
        case .disconnected:
            return "Device disconnected — try syncing again"
        case .serviceNotFound:
            return "BLE service not found — device may need a firmware update (note: updates may break OpenPlaudit)"
        case .characteristicsNotFound:
            return "Protocol mismatch — firmware may be incompatible with this version of OpenPlaudit"
        case .handshakeFailed:
            return "Authentication failed — check your binding token in Settings"
        case .notConnected:
            return "Not connected — try Sync Now"
        case .timeout(let msg):
            return "Timeout: \(msg) — try moving closer or restarting the device"
        case .transferRejected(let s):
            return "Transfer rejected (status=\(s)) — ensure device is not recording"
        case .noResponse(let msg):
            return "No response: \(msg) — device may be busy or out of range"
        }
    }

    /// Get exact WAV duration via AVAudioFile; returns nil on failure.
    static func wavDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Extract the first ~60 characters of the transcript text from a JSON file.
    static func transcriptPreview(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(57)) + "..."
    }

    // MARK: - Config Persistence

    /// Save config to TOML (without token) and token to Keychain.
    /// Returns an error message on failure, nil on success.
    @discardableResult
    public func persistConfig() -> String? {
        do {
            try saveConfigWithKeychain(config)
            return nil
        } catch {
            log.error("Config save failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func addRecentRecording(sid: UInt32, duration: Double?, filename: String) {
        let dirs = getOutputDirs(config)
        let jsonPath = dirs.transcripts.appendingPathComponent("\(filename).json")
        let preview = Self.transcriptPreview(jsonPath)
        let recording = RecentRecording(
            id: sid,
            date: Date(timeIntervalSince1970: TimeInterval(sid)),
            durationSeconds: duration,
            filename: filename,
            transcriptPreview: preview
        )
        recentRecordings.insert(recording, at: 0)
        if recentRecordings.count > 10 { recentRecordings.removeLast() }
    }

    /// Rebuild recent recordings from state.json and audio directory.
    /// Called on launch and after state restore.
    public func rebuildRecentRecordings() {
        let dirs = getOutputDirs(config)
        var recordings: [RecentRecording] = []

        for (key, entry) in state.allEntries {
            guard entry["decoded_at"] != nil || entry["transcribed_at"] != nil,
                  let sid = UInt32(key) else { continue }

            let fname = sessionFilename(sid)
            let wavPath = dirs.audio.appendingPathComponent("\(fname).wav")

            let duration = Self.wavDuration(wavPath)

            // Load transcript preview (first 60 chars of full text)
            let jsonPath = dirs.transcripts.appendingPathComponent("\(fname).json")
            let preview = Self.transcriptPreview(jsonPath)

            recordings.append(RecentRecording(
                id: sid,
                date: Date(timeIntervalSince1970: TimeInterval(sid)),
                durationSeconds: duration,
                filename: fname,
                transcriptPreview: preview
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
