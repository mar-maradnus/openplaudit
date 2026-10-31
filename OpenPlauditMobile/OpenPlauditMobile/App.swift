
import SwiftUI
import SwiftData

@main
struct OpenPlauditMobileApp: App {
    /// One model for every tab: settings changed in one place apply everywhere.
    @StateObject private var syncModel = DeviceSyncModel()

    init() {
        // BGTaskScheduler requires handlers registered before launch completes.
        BackgroundSync.register()
    }

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
                .environmentObject(syncModel)
                .onAppear { BackgroundSync.schedule() }
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Root content view with tab navigation.
struct ContentView: View {
    @AppStorage("selectedTab") private var selectedTab: Int = 2

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

            DeviceSyncView()
                .tabItem {
                    Label("Device", systemImage: "dot.radiowaves.left.and.right")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(3)
        }
        .tint(Theme.accent)
    }
}
