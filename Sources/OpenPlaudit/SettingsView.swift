/// Settings window — sidebar navigation with device, output, transcription, sync sections.

import AppKit
import AVFoundation
import SwiftUI
import SyncEngine
import TranscriptionKit
import MeetingKit
import SummarisationKit

struct SettingsView: View {
    @ObservedObject var engine: SyncEngine
    @ObservedObject var meetingEngine: MeetingEngine

    @State private var address: String = ""
    @State private var token: String = ""
    @State private var deviceName: String = ""
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
    @State private var modelFileInfo: String?

    // AI config state
    @State private var diarizationEnabled: Bool = false
    @State private var maxSpeakers: Int = 6
    @State private var summarisationEnabled: Bool = false
    @State private var summarisationModel: String = "qwen2.5:3b"
    @State private var defaultTemplate: String = "key_points"
    @State private var ollamaURL: String = "http://localhost:11434"

    // Meeting config state
    @State private var meetingEnabled: Bool = false
    @State private var meetingAutoRecord: Bool = false
    @State private var meetingIncludeBrowsers: Bool = false
    @State private var meetingConsentAcknowledged: Bool = false
    @State private var meetingMonitoredApps: Set<String> = []
    @State private var meetingMicDeviceID: String = ""
    @State private var availableMics: [(id: String, name: String)] = []

    // Diagnostics state
    @State private var diagnosticsMessage: String?
    @State private var isExportingDiagnostics = false

    enum SettingsSection: String, CaseIterable, Identifiable {
        case device = "Device"
        case output = "Output"
        case transcription = "Transcription"
        case ai = "AI"
        case sync = "Sync"
        case meetings = "Meetings"
        case support = "Support"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .device: return "antenna.radiowaves.left.and.right"
            case .output: return "folder"
            case .transcription: return "text.bubble"
            case .ai: return "brain"
            case .sync: return "arrow.triangle.2.circlepath"
            case .meetings: return "video.fill"
            case .support: return "lifepreserver"
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
        .frame(width: 560, height: 400)
        .onAppear {
            loadFromConfig()
            refreshModelInfo()
        }
    }

    // MARK: - Detail Views

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .device: deviceSection
        case .output: outputSection
        case .transcription: transcriptionSection
        case .ai: aiSection
        case .sync: syncSection
        case .meetings: meetingsSection
        case .support: supportSection
        }
    }

    private var deviceSection: some View {
        Form {
            Section {
                if !deviceName.isEmpty {
                    LabeledContent("Device Name:", value: deviceName)
                        .accessibilityLabel("Device name: \(deviceName)")
                }
                TextField("Device Address (UUID):", text: $address)
                    .accessibilityLabel("Device Bluetooth address")
                SecureField("Binding Token:", text: $token)
                    .accessibilityLabel("Device binding token")
            } footer: {
                if address.isEmpty {
                    Text("Enter the BLE UUID of your PLAUD Note and the binding token from pairing.")
                }
            }
            saveRow
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var outputSection: some View {
        Form {
            Section {
                HStack {
                    TextField("Output Directory:", text: $baseDir)
                        .accessibilityLabel("Output directory path")
                    Button("Browse…") { browseOutputDir() }
                        .accessibilityLabel("Choose output directory")
                }
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
                    Text("Tiny (~75 MB)").tag("tiny")
                    Text("Base (~142 MB)").tag("base")
                    Text("Small (~466 MB)").tag("small")
                    Text("Medium (~1.5 GB)").tag("medium")
                    Text("Large (~3.1 GB)").tag("large")
                }
                .accessibilityLabel("Whisper model size")
                TextField("Language:", text: $language)
                    .accessibilityLabel("Transcription language code")
            } footer: {
                if let info = modelFileInfo {
                    Text(info)
                } else {
                    Text("Models are downloaded on first use from Hugging Face.")
                }
            }

            Section {
                Button("Re-download Model") { redownloadModel() }
                    .accessibilityLabel("Re-download the selected whisper model")
            } footer: {
                Text("Forces a fresh download of the selected model, replacing any existing file.")
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
                    .accessibilityLabel("Enable automatic sync")
                Stepper("Interval: \(autoSyncIntervalMinutes) min",
                        value: $autoSyncIntervalMinutes, in: 1...120)
                    .disabled(!autoSyncEnabled)
                    .accessibilityLabel("Auto-sync interval in minutes")
            }

            Section {
                Toggle("Delete local audio files", isOn: $autoDelete)
                    .accessibilityLabel("Delete local WAV files after transcription")
            } header: {
                Text("After Transcription")
            } footer: {
                Text("Removes the decoded WAV from your Mac after transcription completes. "
                   + "Does not affect recordings on the device. "
                   + "The device does not support remote file deletion.")
            }

            Section("Files") {
                Toggle("Keep raw Opus files", isOn: $keepRaw)
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

    private var aiSection: some View {
        Form {
            Section {
                Toggle("Enable speaker diarization", isOn: $diarizationEnabled)
                    .accessibilityLabel("Enable speaker identification")
                Stepper("Max speakers: \(maxSpeakers)", value: $maxSpeakers, in: 2...12)
                    .disabled(!diarizationEnabled)
                    .accessibilityLabel("Maximum number of speakers to detect")
            } header: {
                Text("Speaker Diarization")
            } footer: {
                Text("Identifies who said what using MFCC audio features and clustering. Runs locally after transcription.")
            }

            Section {
                Toggle("Enable summarisation", isOn: $summarisationEnabled)
                    .accessibilityLabel("Enable LLM summarisation")
                TextField("Ollama URL:", text: $ollamaURL)
                    .disabled(!summarisationEnabled)
                    .accessibilityLabel("Ollama server URL")
                TextField("Model:", text: $summarisationModel)
                    .disabled(!summarisationEnabled)
                    .accessibilityLabel("Summarisation model name")
                Picker("Default template:", selection: $defaultTemplate) {
                    ForEach(builtInTemplates) { tmpl in
                        Text(tmpl.name).tag(tmpl.id)
                    }
                }
                .disabled(!summarisationEnabled)
                .accessibilityLabel("Default summarisation template")
            } header: {
                Text("Summarisation")
            } footer: {
                Text("Generates summaries using a local Ollama model. Requires 'ollama serve' running.")
            }

            saveRow
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var meetingsSection: some View {
        Form {
            if !meetingConsentAcknowledged {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recording Consent")
                            .font(.headline)
                        Text("OpenPlaudit will capture audio from meeting apps on your Mac. You are responsible for ensuring compliance with local recording consent laws.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("I Understand") {
                            meetingConsentAcknowledged = true
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Recording") {
                Toggle("Enable meeting recording", isOn: $meetingEnabled)
                    .disabled(!meetingConsentAcknowledged)
                Toggle("Auto-record when meeting detected", isOn: $meetingAutoRecord)
                    .disabled(!meetingEnabled || !meetingConsentAcknowledged)
            }

            Section("Monitored Apps") {
                ForEach(MeetingApp.allCases.filter({ !$0.isBrowser })) { app in
                    Toggle(app.displayName, isOn: Binding(
                        get: { meetingMonitoredApps.contains(app.rawValue) },
                        set: { isOn in
                            if isOn { meetingMonitoredApps.insert(app.rawValue) }
                            else { meetingMonitoredApps.remove(app.rawValue) }
                        }
                    ))
                }

                Toggle("Include browsers (approximate)", isOn: $meetingIncludeBrowsers)
                if meetingIncludeBrowsers {
                    ForEach(MeetingApp.allCases.filter(\.isBrowser)) { app in
                        Toggle(app.displayName, isOn: Binding(
                            get: { meetingMonitoredApps.contains(app.rawValue) },
                            set: { isOn in
                                if isOn { meetingMonitoredApps.insert(app.rawValue) }
                                else { meetingMonitoredApps.remove(app.rawValue) }
                            }
                        ))
                        .padding(.leading, 16)
                    }
                }
            }

            Section {
                Picker("Input device:", selection: $meetingMicDeviceID) {
                    Text("System Default").tag("")
                    ForEach(availableMics, id: \.id) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Select the microphone used during meeting recording.")
            }

            saveRow
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear { refreshMicDevices() }
    }

    private var supportSection: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Export a diagnostics bundle for support. This collects system info, redacted config, state summaries, error logs, and recent os_log output. No data is sent automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Export Diagnostics…") { exportDiagnostics() }
                            .disabled(isExportingDiagnostics)
                        if isExportingDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if let msg = diagnosticsMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(msg.contains("Saved") ? .green : .red)
                    }
                }
            } header: {
                Text("Diagnostics")
            }

            Section {
                LabeledContent("Error journal entries:", value: "\(ErrorJournal.shared.entryCount)")
                Button("Open Data Folder…") {
                    let path = NSString(string: "~/.local/share/openplaudit").expandingTildeInPath
                    let url = URL(fileURLWithPath: path)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                }
                Button("Open Logs in Console…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                }
            } header: {
                Text("Tools")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Save Diagnostics"
        panel.nameFieldStringValue = "openplaudit-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            isExportingDiagnostics = true
            diagnosticsMessage = nil

            Task {
                do {
                    let outputDir = url.deletingLastPathComponent()
                    let zipURL = try DiagnosticsExporter.export(
                        config: engine.config,
                        to: outputDir
                    )
                    // Rename to the user's chosen filename if different
                    if zipURL.lastPathComponent != url.lastPathComponent {
                        try? FileManager.default.removeItem(at: url)
                        try FileManager.default.moveItem(at: zipURL, to: url)
                    }
                    diagnosticsMessage = "Saved to \(url.lastPathComponent)"
                } catch {
                    diagnosticsMessage = error.localizedDescription
                }
                isExportingDiagnostics = false
            }
        }
    }

    private func refreshMicDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        availableMics = discovery.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
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
        deviceName = cfg.device.name
        baseDir = cfg.output.baseDir
        model = cfg.transcription.model
        language = cfg.transcription.language
        keepRaw = cfg.sync.keepRaw
        autoDelete = cfg.sync.autoDeleteLocalAudio
        notificationsEnabled = cfg.notifications.enabled
        showPreview = cfg.notifications.showPreview
        autoSyncEnabled = cfg.sync.autoSyncEnabled
        autoSyncIntervalMinutes = cfg.sync.autoSyncIntervalMinutes

        diarizationEnabled = cfg.diarization.enabled
        maxSpeakers = cfg.diarization.maxSpeakers
        summarisationEnabled = cfg.summarisation.enabled
        summarisationModel = cfg.summarisation.model
        defaultTemplate = cfg.summarisation.defaultTemplate
        ollamaURL = cfg.summarisation.ollamaURL

        meetingEnabled = cfg.meeting.enabled
        meetingAutoRecord = cfg.meeting.autoRecord
        meetingIncludeBrowsers = cfg.meeting.includeBrowsers
        meetingConsentAcknowledged = cfg.meeting.consentAcknowledged
        meetingMonitoredApps = Set(cfg.meeting.monitoredApps)
        meetingMicDeviceID = cfg.meeting.micDeviceID
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

        engine.config.diarization.enabled = diarizationEnabled
        engine.config.diarization.maxSpeakers = maxSpeakers
        engine.config.summarisation.enabled = summarisationEnabled
        engine.config.summarisation.model = summarisationModel
        engine.config.summarisation.defaultTemplate = defaultTemplate
        engine.config.summarisation.ollamaURL = ollamaURL

        engine.config.meeting.enabled = meetingEnabled
        engine.config.meeting.autoRecord = meetingAutoRecord
        engine.config.meeting.includeBrowsers = meetingIncludeBrowsers
        engine.config.meeting.consentAcknowledged = meetingConsentAcknowledged
        engine.config.meeting.monitoredApps = Array(meetingMonitoredApps)
        engine.config.meeting.micDeviceID = meetingMicDeviceID

        saveError = engine.persistConfig()

        // Sync meeting config to engine and restart monitoring
        meetingEngine.config = engine.config
        meetingEngine.restartMonitoring()

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

    // MARK: - Browse Output Directory

    private func browseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select the output directory for recordings and transcripts"
        if panel.runModal() == .OK, let url = panel.url {
            baseDir = url.path
        }
    }

    // MARK: - Model Info

    private func refreshModelInfo() {
        let filename = "ggml-\(model).bin"
        let path = modelsDir.appendingPathComponent(filename)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            modelFileInfo = "Model '\(model)' not yet downloaded."
            return
        }
        if let attrs = try? fm.attributesOfItem(atPath: path.path),
           let size = attrs[FileAttributeKey.size] as? Int,
           let date = attrs[FileAttributeKey.modificationDate] as? Date {
            let sizeMB = Double(size) / 1_048_576.0
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            modelFileInfo = String(format: "Downloaded: %@  (%.0f MB)", fmt.string(from: date), sizeMB)
        }
    }

    private func redownloadModel() {
        let filename = "ggml-\(model).bin"
        let path = modelsDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: path)
        modelFileInfo = "Model deleted. It will be re-downloaded on next transcription."
    }
}
