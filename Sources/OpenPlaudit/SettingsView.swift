/// Settings window — device, output, transcription, sync tabs.

import SwiftUI
import SyncEngine

struct SettingsView: View {
    @ObservedObject var engine: SyncEngine

    @State private var address: String = ""
    @State private var token: String = ""
    @State private var baseDir: String = ""
    @State private var model: String = ""
    @State private var language: String = ""
    @State private var keepRaw: Bool = false
    @State private var autoDelete: Bool = false
    @State private var notificationsEnabled: Bool = true
    @State private var showPreview: Bool = true
    @State private var autoSyncEnabled: Bool = false
    @State private var autoSyncIntervalMinutes: Int = 30
    @State private var restoreMessage: String?

    var body: some View {
        TabView {
            deviceTab
                .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }

            outputTab
                .tabItem { Label("Output", systemImage: "folder") }

            transcriptionTab
                .tabItem { Label("Transcription", systemImage: "text.bubble") }

            syncTab
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 450, height: 300)
        .onAppear { loadFromConfig() }
    }

    // MARK: - Tabs

    private var deviceTab: some View {
        Form {
            TextField("Device Address (UUID):", text: $address)
            SecureField("Binding Token:", text: $token)
            Button("Save") { saveConfig() }
        }
        .padding()
    }

    private var outputTab: some View {
        Form {
            TextField("Output Directory:", text: $baseDir)
            Text("Audio: <base>/audio, Transcripts: <base>/transcripts")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Save") { saveConfig() }
        }
        .padding()
    }

    private var transcriptionTab: some View {
        Form {
            Picker("Model:", selection: $model) {
                Text("Tiny").tag("tiny")
                Text("Base").tag("base")
                Text("Small").tag("small")
                Text("Medium").tag("medium")
                Text("Large").tag("large")
            }
            TextField("Language:", text: $language)
            Button("Save") { saveConfig() }
        }
        .padding()
    }

    private var syncTab: some View {
        Form {
            Toggle("Keep raw Opus files", isOn: $keepRaw)
            Toggle("Auto-delete local audio after transcription", isOn: $autoDelete)
            Toggle("Notifications enabled", isOn: $notificationsEnabled)
            Toggle("Show transcript preview in notifications", isOn: $showPreview)

            Divider()

            Toggle("Auto-sync enabled", isOn: $autoSyncEnabled)
            Stepper("Sync interval: \(autoSyncIntervalMinutes) min",
                    value: $autoSyncIntervalMinutes, in: 1...120)
                .disabled(!autoSyncEnabled)

            Button("Save") { saveConfig() }

            Divider()

            HStack {
                Button("Restore State from Backup") { restoreState() }
                    .disabled(!engine.state.hasBackup)
                if let msg = restoreMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.contains("Restored") ? .green : .red)
                }
            }
            Text("Recovers session tracking from the last known good state if the state file becomes corrupted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Config Bridge

    private func loadFromConfig() {
        let cfg = engine.config
        address = cfg.device.address
        // Token comes from Keychain (already loaded into engine.config)
        token = cfg.device.token
        baseDir = cfg.output.baseDir
        model = cfg.transcription.model
        language = cfg.transcription.language
        keepRaw = cfg.sync.keepRaw
        autoDelete = cfg.sync.autoDeleteLocalAudio
        notificationsEnabled = cfg.notifications.enabled
        showPreview = cfg.notifications.showPreview
        autoSyncEnabled = cfg.sync.autoSyncEnabled
        autoSyncIntervalMinutes = cfg.sync.autoSyncIntervalMinutes
    }

    private func saveConfig() {
        engine.config.device.address = address
        engine.config.device.token = token
        engine.config.output.baseDir = baseDir
        engine.config.transcription.model = model
        engine.config.transcription.language = language
        engine.config.sync.keepRaw = keepRaw
        engine.config.sync.autoDeleteLocalAudio = autoDelete
        engine.config.notifications.enabled = notificationsEnabled
        engine.config.notifications.showPreview = showPreview
        engine.config.sync.autoSyncEnabled = autoSyncEnabled
        engine.config.sync.autoSyncIntervalMinutes = autoSyncIntervalMinutes

        // Persist to TOML (without token) + Keychain (token)
        engine.persistConfig()

        // Apply auto-sync change immediately
        if autoSyncEnabled {
            engine.startAutoSync(intervalMinutes: autoSyncIntervalMinutes)
        } else {
            engine.stopAutoSync()
        }
    }

    private func restoreState() {
        do {
            try engine.state.restoreFromBackup()
            engine.rebuildRecentRecordings()
            restoreMessage = "Restored successfully"
        } catch {
            restoreMessage = error.localizedDescription
        }
    }
}
