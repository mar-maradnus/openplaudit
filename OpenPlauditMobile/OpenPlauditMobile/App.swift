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
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Root content view with tab navigation.
struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            RecordingView()
                .tabItem {
                    Label("Record", systemImage: "mic.fill")
                }
                .tag(0)

            RecordingListView()
                .tabItem {
                    Label("Recordings", systemImage: "list.bullet")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .tint(Theme.accent)
    }
}
