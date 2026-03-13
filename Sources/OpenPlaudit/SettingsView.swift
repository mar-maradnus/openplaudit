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
        .frame(width: 450, height: 250)
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
            Button("Save") { saveConfig() }
        }
        .padding()
    }

    // MARK: - Config Bridge

    private func loadFromConfig() {
        let cfg = engine.config
        address = cfg.device.address
        token = cfg.device.token
        baseDir = cfg.output.baseDir
        model = cfg.transcription.model
        language = cfg.transcription.language
        keepRaw = cfg.sync.keepRaw
        autoDelete = cfg.sync.autoDeleteLocalAudio
        notificationsEnabled = cfg.notifications.enabled
        showPreview = cfg.notifications.showPreview
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

        // Persist to TOML for CLI compatibility
        engine.persistConfig()
    }
}
