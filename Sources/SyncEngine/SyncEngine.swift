/// Sync orchestrator — download, decode, transcribe pipeline.
///
/// Ported from Python CLI `src/plaude/sync.py`.

import Foundation
import BLEKit
import AudioKit
import TranscriptionKit

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
    private var isSyncing = false
    private lazy var transcriber = Transcriber(model: config.transcription.model)

    public init(config: AppConfig = AppConfig(), statePath: URL = defaultStatePath) {
        self.config = config
        self.state = SessionState(path: statePath)
    }

    // MARK: - Auto-Sync

    /// Start periodic auto-sync at the configured interval (minutes).
    public func startAutoSync(intervalMinutes: Int = 30) {
        stopAutoSync()
        let interval = TimeInterval(max(intervalMinutes, 1) * 60)
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isSyncing else { return }
                try? await self.runSync()
            }
        }
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
            throw SyncError.notConfigured
        }

        let dirs = getOutputDirs(config)
        let fm = FileManager.default
        try fm.createDirectory(at: dirs.audio, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirs.transcripts, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirs.raw, withIntermediateDirectories: true)

        guard !isSyncing else { return 0 }
        isSyncing = true
        status = .connecting
        let client = PlaudClient(address: config.device.address, token: config.device.token)
        self.client = client

        defer {
            Task { await client.disconnect() }
            self.client = nil
            self.isSyncing = false
            status = .idle
        }

        try await client.connect()
        isConnected = true

        guard try await client.handshake() else {
            throw SyncError.handshakeFailed
        }
        try await client.timeSync()

        let sessions = try await client.getSessions()
        if sessions.isEmpty { return 0 }

        // Filter to sessions that are not fully complete
        let pending = sessions.filter { !state.isComplete($0.sessionID) }
        if pending.isEmpty { return 0 }

        var completedCount = 0

        for (index, session) in pending.enumerated() {
            status = .syncing(current: index + 1, total: pending.count)
            let sid = session.sessionID
            let fname = sessionFilename(sid)

            do {
                let rawPath = config.sync.keepRaw
                    ? dirs.raw.appendingPathComponent("\(fname).opus")
                    : nil
                let wavPath = dirs.audio.appendingPathComponent("\(fname).wav")

                // Phase 1: Download
                if state.needsDownload(sid) {
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

                    if let rawPath {
                        try rawData.write(to: rawPath, options: .atomic)
                    }

                    state.markDownloaded(sid)
                    try state.saveAtomically()

                    // Phase 2: Decode
                    let pcm = try decodeOpusRaw(rawData)
                    try saveWAV(pcm, to: wavPath)

                    state.markDecoded(sid)
                    try state.saveAtomically()

                    let duration = Double(pcm.count) / (16000.0 * 2.0)
                    addRecentRecording(sid: sid, duration: duration, filename: fname)
                } else if state.needsDecode(sid) {
                    // Already downloaded, needs decode — try to find raw data
                    if let rawPath, fm.fileExists(atPath: rawPath.path) {
                        let rawData = try Data(contentsOf: rawPath)
                        let pcm = try decodeOpusRaw(rawData)
                        try saveWAV(pcm, to: wavPath)
                        state.markDecoded(sid)
                        try state.saveAtomically()
                    }
                }

                // Phase 3: Transcription
                if state.needsTranscription(sid) {
                    let result = try await transcriber.transcribe(
                        wavPath: wavPath,
                        language: config.transcription.language
                    )
                    let jsonPath = dirs.transcripts.appendingPathComponent("\(fname).json")
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(result).write(to: jsonPath, options: .atomic)

                    state.markTranscribed(sid)
                    try state.saveAtomically()
                }

                if config.notifications.enabled {
                    sendNotification(
                        title: "OpenPlaudit",
                        body: "Recording synced: \(fname)",
                        subtitle: formatLocalTime(sid)
                    )
                }

                completedCount += 1

            } catch {
                state.markFailed(sid, reason: "\(type(of: error)): \(error.localizedDescription)")
                try? state.saveAtomically()
            }

            progress = nil
        }

        return completedCount
    }

    // MARK: - Config Persistence

    /// Save the current config to TOML (for CLI compatibility).
    public func persistConfig() {
        try? saveConfig(config)
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
