/// OpenPlaudit Mobile — iPhone companion recorder app.
///
/// Lightweight recorder that syncs to the macOS app for AI processing.
/// No local transcription — the Mac handles the full pipeline.

import SwiftUI
import SwiftData

@main
struct OpenPlauditMobileApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([RecordingModel.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Root content view with tab navigation.
struct ContentView: View {
    var body: some View {
        TabView {
            RecordingView()
                .tabItem {
                    Label("Record", systemImage: "mic.fill")
                }

            RecordingListView()
                .tabItem {
                    Label("Recordings", systemImage: "list.bullet")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}
