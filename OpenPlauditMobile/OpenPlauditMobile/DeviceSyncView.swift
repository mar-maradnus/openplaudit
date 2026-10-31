
import SwiftUI
import BLEKit

struct DeviceSyncView: View {
    @EnvironmentObject private var model: DeviceSyncModel
    @State private var showSettings = false
    @State private var showScanner = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if !model.isConfigured {
                    Section {
                    SecureField("Device token", text: $model.deviceToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Device token")
                } footer: {
                    Text("From config.toml on the Mac (device.token). Not in the credentials file.")
                }
                Section {
                        Button("Set up device access") { showSettings = true }
                    } footer: {
                        Text("Needs your device credentials and a transcription key. Nothing leaves the phone except the audio you choose to transcribe.")
                    }
                } else {
                    Section {
                        Toggle("Sync when I open the app", isOn: Binding(
                            get: { model.autoSyncOnOpen },
                            set: { model.setAutoSync($0) }))
                    } footer: {
                        Text("iOS suspends Bluetooth apps in the background, so a transfer has to run with the app open. The recorder frees a recording itself once a transfer completes.")
                    }
                    deviceSection
                    if !model.recordings.isEmpty { recordingsSection }
                }
            }
            .navigationTitle("From Device")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { DeviceSettingsView(model: model) }
            .refreshable { await model.scan() }
            .task { await model.autoSyncIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    Task { await model.autoSyncIfNeeded() }
                case .background:
                    BackgroundSync.schedule()
                default:
                    break
                }
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch model.stage {
        case .idle:
            EmptyView()
        case .scanning:
            LabeledContent("Scanning…") { ProgressView() }
        case .connecting:
            LabeledContent("Connecting…") { ProgressView() }
        case .authenticating:
            LabeledContent("Authenticating…") { ProgressView() }
        case .listing:
            LabeledContent("Reading device…") { ProgressView() }
        case .downloading(let p):
            VStack(alignment: .leading) {
                Text("Downloading \(Int(p * 100))%")
                ProgressView(value: p)
            }
        case .decrypting:
            LabeledContent("Decrypting…") { ProgressView() }
        case .transcribing(let d, let t):
            VStack(alignment: .leading) {
                Text("Transcribing \(d)/\(t)")
                ProgressView(value: Double(d), total: Double(max(t, 1)))
            }
        case .done(let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(msg)
            }
        case .failed(let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg)
            }
        }
    }

    @ViewBuilder private var deviceSection: some View {
        Section {
            if let address = model.deviceAddress.nonEmpty, !showScanner {
                HStack(spacing: 14) {
                    Image(systemName: batterySymbol)
                        .font(.title2)
                        .foregroundStyle(batteryColour)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.deviceName ?? "Your PLAUD")
                            .font(Theme.body)
                        Text(model.battery.map {
                            model.isCharging ? "\($0)% · charging" : "\($0)% battery"
                        } ?? "Battery unknown")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                Button {
                    Task { await model.sync(address: address) }
                } label: {
                    HStack {
                        Label(model.isBusy ? "Syncing…" : "Sync now",
                              systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if model.isBusy { ProgressView() }
                    }
                }
                .disabled(!isIdle)

                if case .downloading(let p) = model.stage {
                    ProgressView(value: p) { Text("\(Int(p * 100))%") }
                }
                if let line = model.lastResultLine {
                    Text(line)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Button("Pair a different recorder") { showScanner = true }
                    .font(Theme.caption)
            } else {
                if model.devices.isEmpty {
                    Button("Scan for recorder") { Task { await model.scan() } }
                } else {
                    ForEach(model.devices, id: \.identifier) { device in
                        Button {
                            Task { await model.sync(address: device.identifier.uuidString) }
                        } label: {
                            HStack {
                                Text(device.name)
                                Spacer()
                                Text("\(device.rssi) dBm").foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!isIdle)
                    }
                    Button("Scan again") { Task { await model.scan() } }
                }
                if model.deviceAddress.nonEmpty != nil {
                    Button("Cancel") { showScanner = false }
                }
            }
        } header: {
            Text("Recorder")
        }
    }

    private var batterySymbol: String {
        if model.isCharging { return "battery.100percent.bolt" }
        guard let b = model.battery else { return "battery.0percent" }
        switch b {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default:    return "battery.0percent"
        }
    }

    private var batteryColour: Color {
        if model.isCharging { return .green }
        guard let b = model.battery else { return Theme.textTertiary }
        return b <= 15 ? .red : (b <= 30 ? .orange : .green)
    }

    @ViewBuilder private var recordingsSection: some View {
        Section("On device") {
            ForEach(model.recordings, id: \.sessionID) { session in
                HStack {
                    Text(DeviceSyncModel.title(for: session.sessionID))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(session.fileSize), countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isIdle: Bool {
        switch model.stage {
        case .idle, .done, .failed: return true
        default: return false
        }
    }
}

struct DeviceSettingsView: View {
    @ObservedObject var model: DeviceSyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickingFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $model.credentialsMarkdown)
                        .frame(minHeight: 140)
                        .font(.caption.monospaced())
                } header: {
                    Text("Device credentials")
                } footer: {
                    Text("Paste the contents of plaud-credentials.md. Stored in the Keychain.")
                }
                Section {
                    Picker("Destination", selection: $model.destination) {
                        Text("Files folder").tag("folder")
                        Text("Vault (MCP)").tag("mcp")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Where notes go")
                }
                if model.destination == "mcp" {
                    Section {
                        TextField("MCP endpoint URL", text: $model.mcpURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Token", text: $model.mcpToken)
                        TextField("Agent ID (optional)", text: $model.mcpAgentID).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("Backend server (blank for a plain MCP server)", text: $model.mcpServer, prompt: Text("e.g. obsidian")).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("Vault folder", text: $model.vaultFolder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Test connection") { Task { await model.testNoteDelivery() } }
                        if let r = model.testResult {
                            Text(r).font(.caption)
                                .foregroundStyle(r.hasPrefix("OK") ? .green : .orange)
                        }
                    } header: {
                        Text("MCP")
                    } footer: {
                        Text("Writes to \(model.vaultFolder)/<date>/<time>/<note>.md via MCP — nothing is stored on the phone.")
                    }
                }
                Section {
                    Button(model.outputFolderName == nil
                           ? "Choose folder…"
                           : "Change folder…") { pickingFolder = true }
                    if let name = model.outputFolderName {
                        Text(name).foregroundStyle(.secondary)
                        Button("Use the app's own folder", role: .destructive) {
                            model.clearOutputFolder()
                        }
                    }
                } header: {
                    Text("Save notes to")
                } footer: {
                    Text(model.outputFolderName == nil
                         ? "Default: the app's folder, visible in Files. Choose iCloud Drive or a vault folder to keep notes off this phone."
                         : "Notes are written here instead of the phone.")
                }
                Section("Transcription") {
                    TextField("Endpoint", text: $model.endpoint)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $model.apiKey)
                    TextField("Model", text: $model.model)
                        .autocorrectionDisabled()
                }
            }
            .fileImporter(isPresented: $pickingFolder,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.setOutputFolder(url)
                }
            }
            .navigationTitle("Device Setup")
            .safeAreaInset(edge: .bottom) {
                if let err = model.settingsError {
                    Text(err).font(.caption).foregroundStyle(.orange).padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveSettings(); dismiss() }
                }
            }
        }
    }
}
