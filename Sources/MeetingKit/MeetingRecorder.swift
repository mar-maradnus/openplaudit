/// Meeting recorder — coordinates audio capture session with WAV output.
///
/// Manages the lifecycle of a single meeting recording: start → capture → stop → WAV.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "meeting-recorder")

/// Result of a completed meeting recording.
public struct MeetingRecording: Sendable {
    public let wavPath: URL
    public let appName: String
    public let startedAt: Date
    public let durationSeconds: Double
}

/// Records a single meeting session.
public final class MeetingRecorder: @unchecked Sendable {
    private var captureSession: AudioCaptureSession?
    private let outputBaseDir: URL
    private var appName: String = ""
    private var startedAt: Date?

    public var isRecording: Bool { captureSession != nil }

    public init(outputBaseDir: URL) {
        self.outputBaseDir = outputBaseDir
    }

    /// Start recording audio from the specified app.
    public func start(appBundleID: String, appDisplayName: String, micDeviceID: String = "") async throws {
        guard captureSession == nil else {
            log.warning("Already recording — ignoring start request")
            return
        }

        // Create a temp directory for chunk files
        let sessionDir = outputBaseDir.appendingPathComponent(".recording_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let session = AudioCaptureSession(outputDir: sessionDir)
        try await session.start(appBundleID: appBundleID, micDeviceID: micDeviceID)

        captureSession = session
        appName = appDisplayName
        startedAt = Date()

        log.info("Recording started for \(appDisplayName, privacy: .public)")
    }

    /// Stop recording and return the completed recording info.
    public func stop() async throws -> MeetingRecording {
        guard let session = captureSession else {
            throw RecorderError.notRecording
        }

        let wavPath = try await session.stop()
        let duration = session.durationSeconds
        let app = appName
        let started = startedAt ?? Date()

        // Move WAV from temp dir to final location
        let finalPath = outputBaseDir.appendingPathComponent(wavPath.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: finalPath.path) {
            try fm.removeItem(at: finalPath)
        }
        try fm.moveItem(at: wavPath, to: finalPath)

        // Clean up temp session dir
        let sessionDir = wavPath.deletingLastPathComponent()
        try? fm.removeItem(at: sessionDir)

        captureSession = nil
        startedAt = nil

        log.info("Recording stopped: \(finalPath.lastPathComponent, privacy: .public) (\(String(format: "%.1f", duration))s)")

        return MeetingRecording(
            wavPath: finalPath,
            appName: app,
            startedAt: started,
            durationSeconds: duration
        )
    }

    /// Cancel an in-progress recording without saving.
    public func cancel() async {
        guard let session = captureSession else { return }
        await session.cancel()
        captureSession = nil
        startedAt = nil
        log.info("Recording cancelled")
    }

    /// Current recording duration in seconds (0 if not recording).
    public var currentDuration: Double {
        captureSession?.durationSeconds ?? 0
    }
}

public enum RecorderError: Error, LocalizedError {
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .notRecording: return "Not currently recording"
        }
    }
}
