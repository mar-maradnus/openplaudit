/// Settings window — sidebar navigation with device, output, transcription, sync sections.

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
    @State private var saveError: String?
    @State private var selectedSection: SettingsSection = .device

    enum SettingsSection: String, CaseIterable, Identifiable {
        case device = "Device"
        case output = "Output"
        case transcription = "Transcription"
        case sync = "Sync"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .device: return "antenna.radiowaves.left.and.right"
            case .output: return "folder"
            case .transcription: return "text.bubble"
            case .sync: return "arrow.triangle.2.circlepath"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 180)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 360)
        .onAppear { loadFromConfig() }
    }

    // MARK: - Detail Views

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .device: deviceSection
        case .output: outputSection
        case .transcription: transcriptionSection
        case .sync: syncSection
        }
    }

    private var deviceSection: some View {
        Form {
            Section {
                TextField("Device Address (UUID):", text: $address)
                SecureField("Binding Token:", text: $token)
            }
            saveRow
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var outputSection: some View {
        Form {
            Section {
                TextField("Output Directory:", text: $baseDir)
            } footer: {
                Text("Audio saved to <dir>/audio, transcripts to <dir>/transcripts")
            }
            saveRow
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var transcriptionSection: some View {
        Form {
            Section {
                Picker("Model:", selection: $model) {
                    Text("Tiny").tag("tiny")
                    Text("Base").tag("base")
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                TextField("Language:", text: $language)
            } footer: {
                Text("Models are downloaded on first use. Medium requires ~1.5 GB.")
            }
            saveRow
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var syncSection: some View {
        Form {
            Section("Scheduling") {
                Toggle("Auto-sync enabled", isOn: $autoSyncEnabled)
                Stepper("Interval: \(autoSyncIntervalMinutes) min",
                        value: $autoSyncIntervalMinutes, in: 1...120)
                    .disabled(!autoSyncEnabled)
            }

            Section("Files") {
                Toggle("Keep raw Opus files", isOn: $keepRaw)
                Toggle("Auto-delete audio after transcription", isOn: $autoDelete)
            }

            Section("Notifications") {
                Toggle("Notifications enabled", isOn: $notificationsEnabled)
                Toggle("Show transcript preview", isOn: $showPreview)
                    .disabled(!notificationsEnabled)
            }

            saveRow

            Section("Recovery") {
                HStack {
                    Button("Restore State from Backup") { restoreState() }
                        .disabled(!engine.state.hasBackup)
                    if let msg = restoreMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(msg.contains("Restored") ? .green : .red)
                    }
                }
                Text("Recovers session tracking from the last known good state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    // MARK: - Shared Save Row

    private var saveRow: some View {
        Section {
            HStack {
                Button("Save") { saveConfig() }
                    .keyboardShortcut(.return, modifiers: .command)
                if let err = saveError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
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

        saveError = engine.persistConfig()

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
