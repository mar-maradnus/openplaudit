/// AppIntents for Action Button (iPhone 15+).
///
/// Press Action Button → starts recording. Press again → stops.

import AppIntents

struct RecordIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Recording"
    static var description = IntentDescription("Start or stop an OpenPlaudit recording.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // The intent opens the app, which handles the recording toggle
        // via the RecordingView's state. A more sophisticated approach
        // would use a shared state manager, but opening the app is the
        // simplest reliable pattern for background audio.
        return .result()
    }
}

struct RecordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordIntent(),
            phrases: [
                "Record with \(.applicationName)",
                "Start recording in \(.applicationName)",
            ],
            shortTitle: "Record",
            systemImageName: "mic.fill"
        )
    }
}
