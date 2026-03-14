/// Meeting recording orchestrator — detects meetings, records, transcribes.
///
/// @MainActor ObservableObject that coordinates MeetingDetector,
/// MeetingRecorder, and a shared Transcriber. Publishes state for
/// the menubar UI to observe.

import Foundation
import SyncEngine
import TranscriptionKit
import DiarizationKit
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "meeting-engine")

@MainActor
public final class MeetingEngine: ObservableObject {
    @Published public var recordingState: RecordingState = .idle
    @Published public var detectedApps: [MeetingApp] = []
    @Published public var recentMeetings: [RecentMeeting] = []

    public var config: AppConfig
    public let state: MeetingState
    private let transcriber: Transcriber
    private let detector = MeetingDetector()
    private var recorder: MeetingRecorder?
    private var debounceTask: Task<Void, Never>?
    private var recordingStartTime: Date?

    public enum RecordingState: Equatable {
        case idle
        case monitoring
        case recording(app: String)
        case transcribing
        case error(String)
    }

    public struct RecentMeeting: Identifiable, Equatable {
        public let id: UUID
        public let appName: String
        public let date: Date
        public let durationSeconds: Double
        public let filename: String
    }

    public init(config: AppConfig, transcriber: Transcriber, statePath: URL = defaultMeetingStatePath) {
        self.config = config
        self.transcriber = transcriber
        self.state = MeetingState(path: statePath)
        rebuildRecentMeetings()
    }

    /// Rebuild recent meetings list from persisted state.
    public func rebuildRecentMeetings() {
        var meetings: [RecentMeeting] = []
        for (id, entry) in state.allEntries {
            guard let recordedAt = entry.recordedAt,
                  let filename = entry.filename else { continue }
            let date = ISO8601DateFormatter().date(from: recordedAt) ?? Date()
            meetings.append(RecentMeeting(
                id: UUID(uuidString: id) ?? UUID(),
                appName: entry.appName ?? "Unknown",
                date: date,
                durationSeconds: entry.durationSeconds ?? 0,
                filename: filename
            ))
        }
        recentMeetings = Array(meetings.sorted { $0.date > $1.date }.prefix(10))
    }

    // MARK: - Monitoring

    /// Start monitoring for meeting apps (polling NSWorkspace).
    public func startMonitoring() {
        guard config.meeting.enabled && config.meeting.consentAcknowledged else {
            recordingState = .idle
            return
        }

        recordingState = .monitoring

        detector.onChange = { [weak self] apps, newApps in
            Task { @MainActor in
                self?.onDetectedAppsChanged(apps, newApps: newApps)
            }
        }

        detector.startMonitoring(
            monitoredApps: config.meeting.monitoredApps,
            includeBrowsers: config.meeting.includeBrowsers
        )
    }

    /// Stop monitoring and cancel any in-progress recording.
    public func stopMonitoring() {
        detector.stopMonitoring()
        debounceTask?.cancel()
        debounceTask = nil

        if case .recording = recordingState {
            Task { await cancelRecording() }
        }

        recordingState = .idle
    }

    /// Restart monitoring with current config (call after settings change).
    public func restartMonitoring() {
        stopMonitoring()
        startMonitoring()
    }

    // MARK: - Manual Control

    /// Manually start recording (from menu item).
    public func startManualRecording(app: MeetingApp) async {
        await startRecording(app: app)
    }

    /// Manually stop recording (from menu item).
    public func stopManualRecording() async {
        await stopRecordingAndTranscribe()
    }

    // MARK: - Recording Lifecycle

    private func startRecording(app: MeetingApp) async {
        guard recorder == nil else { return }

        let dirs = getOutputDirs(config)
        let fm = FileManager.default
        try? fm.createDirectory(at: dirs.meetingAudio, withIntermediateDirectories: true)

        let rec = MeetingRecorder(outputBaseDir: dirs.meetingAudio)

        do {
            try await rec.start(appBundleID: app.rawValue, appDisplayName: app.displayName, micDeviceID: config.meeting.micDeviceID)
            recorder = rec
            recordingStartTime = Date()
            recordingState = .recording(app: app.displayName)
        } catch {
            log.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
            recordingState = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() async {
        guard let rec = recorder else { return }

        do {
            let recording = try await rec.stop()
            recorder = nil
            recordingState = .transcribing

            // Transcribe
            let dirs = getOutputDirs(config)
            let fm = FileManager.default
            try? fm.createDirectory(at: dirs.meetingTranscripts, withIntermediateDirectories: true)

            let lang = config.transcription.language
            let t = transcriber
            var result = try await Task.detached {
                try await t.transcribe(wavPath: recording.wavPath, language: lang)
            }.value

            // Diarization: assign speaker labels
            if config.diarization.enabled {
                let maxSpk = config.diarization.maxSpeakers
                let wav = recording.wavPath
                let currentResult = result
                result = try await Task.detached {
                    try await SyncEngine.applyDiarization(to: currentResult, wavPath: wav, maxSpeakers: maxSpk)
                }.value
            }

            let jsonFilename = recording.wavPath
                .deletingPathExtension()
                .lastPathComponent + ".json"
            let jsonPath = dirs.meetingTranscripts.appendingPathComponent(jsonFilename)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: jsonPath, options: .atomic)

            // Persist state
            let meetingID = UUID()
            let meetingIDStr = meetingID.uuidString
            state.markRecorded(
                id: meetingIDStr,
                appName: recording.appName,
                duration: recording.durationSeconds,
                filename: recording.wavPath.lastPathComponent
            )
            state.markTranscribed(id: meetingIDStr)
            try? state.saveAtomically()

            // Add to recent meetings
            let meeting = RecentMeeting(
                id: meetingID,
                appName: recording.appName,
                date: recording.startedAt,
                durationSeconds: recording.durationSeconds,
                filename: recording.wavPath.lastPathComponent
            )
            recentMeetings.insert(meeting, at: 0)
            if recentMeetings.count > 10 { recentMeetings.removeLast() }

            // Notify
            if config.notifications.enabled {
                let body = "Meeting recorded: \(recording.appName) (\(formatDuration(recording.durationSeconds)))"
                let subtitle = config.notifications.showPreview
                    ? String(result.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                    : ""
                sendNotification(title: "OpenPlaudit", body: body, subtitle: subtitle)
            }

            log.info("Meeting recording complete: \(recording.wavPath.lastPathComponent, privacy: .public)")

            // Return to monitoring if still enabled
            if config.meeting.enabled && config.meeting.consentAcknowledged {
                recordingState = .monitoring
            } else {
                recordingState = .idle
            }

        } catch {
            recorder = nil
            let failID = UUID().uuidString
            state.markFailed(id: failID, reason: error.localizedDescription)
            try? state.saveAtomically()
            log.error("Meeting recording/transcription failed: \(error.localizedDescription, privacy: .public)")
            recordingState = .error(error.localizedDescription)
        }
    }

    private func cancelRecording() async {
        await recorder?.cancel()
        recorder = nil
    }

    // MARK: - Auto-Record Logic

    private func onDetectedAppsChanged(_ apps: [MeetingApp], newApps: Set<String>) {
        detectedApps = apps

        guard config.meeting.autoRecord else { return }

        if case .recording = recordingState {
            // If the recorded app disappeared, stop recording after debounce
            if apps.isEmpty {
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                    guard !Task.isCancelled else { return }
                    // Re-check: if still no apps, stop
                    let current = detector.detect(
                        monitoredApps: config.meeting.monitoredApps,
                        includeBrowsers: config.meeting.includeBrowsers
                    )
                    if current.isEmpty {
                        await stopRecordingAndTranscribe()
                    }
                }
            } else {
                debounceTask?.cancel()
                debounceTask = nil
            }
        } else if recordingState == .monitoring {
            // Start recording only if a genuinely NEW app appeared (not already running)
            if let firstNew = apps.first(where: { newApps.contains($0.rawValue) }) {
                let firstApp = firstNew
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10-second debounce
                    guard !Task.isCancelled else { return }
                    // Re-check: still running?
                    let current = detector.detect(
                        monitoredApps: config.meeting.monitoredApps,
                        includeBrowsers: config.meeting.includeBrowsers
                    )
                    if current.contains(where: { $0 == firstApp }) {
                        await startRecording(app: firstApp)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Current recording duration string for display (e.g. "2:34").
    public var recordingDurationString: String {
        guard let start = recordingStartTime else { return "0:00" }
        let elapsed = Date().timeIntervalSince(start)
        return formatDuration(elapsed)
    }
}

private func formatDuration(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds)
    let mins = totalSeconds / 60
    let secs = totalSeconds % 60
    return String(format: "%d:%02d", mins, secs)
}
