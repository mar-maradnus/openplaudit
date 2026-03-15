/// Live Activity for Lock Screen recording indicator.
///
/// Shows elapsed time and a stop button during recording.
/// Requires iOS 16.1+ and ActivityKit.

import ActivityKit
import Foundation

/// Attributes for the recording Live Activity.
struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsedSeconds: Int
        var isRecording: Bool
    }

    var recordingName: String
}

/// Manages the recording Live Activity lifecycle.
@MainActor
final class LiveActivityManager: ObservableObject {
    private var activity: Activity<RecordingActivityAttributes>?

    /// Start a Live Activity for the current recording.
    func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = RecordingActivityAttributes(recordingName: "Recording")
        let state = RecordingActivityAttributes.ContentState(elapsedSeconds: 0, isRecording: true)

        do {
            activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
        } catch {
            // Live Activities may not be available
        }
    }

    /// Update the elapsed time shown in the Live Activity.
    func updateElapsedTime(_ seconds: Int) {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(elapsedSeconds: seconds, isRecording: true)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// End the Live Activity.
    func endActivity() {
        guard let activity else { return }
        self.activity = nil
        let state = RecordingActivityAttributes.ContentState(elapsedSeconds: 0, isRecording: false)
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate) }
    }
}
