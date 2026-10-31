
import Foundation
import SwiftUI
import BLEKit
import PlaudCore
import SharedKit

@MainActor
final class DeviceSyncModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case scanning
        case connecting
        case authenticating
        case listing
        case downloading(Double)
        case decrypting
        case transcribing(Int, Int)
        case done(String)
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var recordings: [RecordingSession] = []
    @Published private(set) var battery: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var stateBytes: [UInt8] = []
    @Published private(set) var lastResultLine: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var lastTranscriptPath: URL?
    @Published var credentialsMarkdown: String = ""
    @Published var deviceAddress: String = ""
    @Published var deviceToken: String = ""
    @Published var endpoint: String = ""
    @Published var apiKey: String = ""
    @Published var model: String = "whisper-1"
    @Published private(set) var settingsError: String?
    @Published private(set) var outputFolderName: String?
    @Published var destination: String = "folder"
    @Published var mcpURL: String = ""
    @Published var mcpToken: String = ""
    @Published var mcpAgentID: String = ""
    @Published var mcpServer: String = ""
    @Published var vaultFolder: String = "Recordings"

    private let credsKey = "plaud.credentials"
    private let addressKey = "plaud.address"
    private let tokenKey = "plaud.token"
    private let outputBookmarkKey = "plaud.outputBookmark"
    private let outputNameKey = "plaud.outputName"
    private let destinationKey = "plaud.destination"
    private let mcpURLKey = "plaud.mcpURL"
    private let mcpTokenKey = "plaud.mcpToken"
    private let vaultFolderKey = "plaud.vaultFolder"
    private let endpointKey = "plaud.endpoint"
    private let apiKeyKey = "plaud.apikey"

    init() {
        credentialsMarkdown = KeychainHelper.load(key: credsKey) ?? ""
        deviceAddress = KeychainHelper.load(key: addressKey) ?? ""
        deviceToken = KeychainHelper.load(key: tokenKey) ?? ""
        outputFolderName = UserDefaults.standard.string(forKey: outputNameKey)
        destination = UserDefaults.standard.string(forKey: destinationKey) ?? "folder"
        mcpURL = UserDefaults.standard.string(forKey: mcpURLKey) ?? mcpURL
        vaultFolder = UserDefaults.standard.string(forKey: vaultFolderKey) ?? vaultFolder
        mcpToken = KeychainHelper.load(key: mcpTokenKey) ?? ""
        mcpAgentID = UserDefaults.standard.string(forKey: "plaud.mcpAgentID") ?? ""
        mcpServer = UserDefaults.standard.string(forKey: "plaud.mcpServer") ?? mcpServer
        model = UserDefaults.standard.string(forKey: "plaud.model") ?? model
        endpoint = KeychainHelper.load(key: endpointKey) ?? endpoint
        apiKey = KeychainHelper.load(key: apiKeyKey) ?? ""
    }

    // The device address is learned by scanning, so it cannot gate this.
    var isConfigured: Bool {
        guard !credentialsMarkdown.isEmpty, !apiKey.isEmpty else { return false }
        let bundled = (try? DeviceCredentials.parse(markdown: credentialsMarkdown))?.deviceToken
        return bundled?.isEmpty == false || !deviceToken.isEmpty
    }

    func saveSettings() {
        settingsError = nil
        do {
            try KeychainHelper.save(key: credsKey, value: credentialsMarkdown)
            try KeychainHelper.save(key: addressKey, value: deviceAddress)
            try KeychainHelper.save(key: tokenKey, value: deviceToken)
            try KeychainHelper.save(key: endpointKey, value: endpoint)
            try KeychainHelper.save(key: apiKeyKey, value: apiKey)
            try KeychainHelper.save(key: mcpTokenKey, value: mcpToken)
            UserDefaults.standard.set(destination, forKey: destinationKey)
            UserDefaults.standard.set(mcpURL, forKey: mcpURLKey)
            UserDefaults.standard.set(vaultFolder, forKey: vaultFolderKey)
            UserDefaults.standard.set(mcpAgentID, forKey: "plaud.mcpAgentID")
            UserDefaults.standard.set(mcpServer, forKey: "plaud.mcpServer")
            UserDefaults.standard.set(model, forKey: "plaud.model")
        } catch {
            settingsError = "Could not save: \(error)"
        }
    }

    func setOutputFolder(_ url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: outputBookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: outputNameKey)
            outputFolderName = url.lastPathComponent
            settingsError = nil
        } catch {
            settingsError = "Could not use that folder: \(error.localizedDescription)"
        }
    }

    func clearOutputFolder() {
        UserDefaults.standard.removeObject(forKey: outputBookmarkKey)
        UserDefaults.standard.removeObject(forKey: outputNameKey)
        outputFolderName = nil
    }

    private func resolveOutputFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: outputBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                relativeTo: nil, bookmarkDataIsStale: &stale) else {
            settingsError = "The output folder is no longer available — pick it again."
            return nil
        }
        return url
    }

    @Published private(set) var testResult: String?

    func testNoteDelivery() async {
        testResult = nil
        guard let url = URL(string: mcpURL), !mcpToken.isEmpty else {
            testResult = "MCP URL or token is empty"
            return
        }
        let root = vaultFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = "\(root.isEmpty ? "Recordings" : root)/connection-test.md"
        do {
            try await noteClient(url).writeNote(
                path: path,
                content: "# Connection test\n\nWritten by the app. Safe to delete.\n")
            testResult = "OK — wrote \(path)"
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func noteClient(_ url: URL) -> MCPNoteClient {
        MCPNoteClient(endpoint: url, token: mcpToken,
                      agentID: mcpAgentID.isEmpty ? nil : mcpAgentID,
                      backendServer: mcpServer.isEmpty ? nil : mcpServer)
    }

    func scan() async {
        stage = .scanning
        devices = await BLEScanner().scan(timeout: 12)
        stage = devices.isEmpty ? .failed("No PLAUD device found — tap Record once to wake it, and make sure the PLAUD app isn't connected.") : .idle
    }

    @Published var autoSyncOnOpen: Bool =
        (UserDefaults.standard.object(forKey: "plaud.autoSync") as? Bool) ?? true
    private var lastAutoSyncAt: Date?

    private var syncedIDs: Set<UInt32> = {
        Set((UserDefaults.standard.array(forKey: "plaud.syncedIDs") as? [Int] ?? []).map(UInt32.init))
    }()

    private func markSynced(_ id: UInt32) {
        syncedIDs.insert(id)
        UserDefaults.standard.set(syncedIDs.map(Int.init), forKey: "plaud.syncedIDs")
    }

    var isBusy: Bool {
        switch stage {
        case .scanning, .connecting, .authenticating, .listing,
             .downloading, .decrypting, .transcribing:
            return true
        case .idle, .done, .failed:
            return false
        }
    }

    func autoSyncIfNeeded(minInterval: TimeInterval = 60) async {
        guard autoSyncOnOpen, isConfigured, !deviceAddress.isEmpty else { return }
        guard !isBusy else { return }
        if let last = lastAutoSyncAt,
           Date().timeIntervalSince(last) < minInterval { return }
        lastAutoSyncAt = Date()
        await sync(address: deviceAddress)
    }

    func setAutoSync(_ on: Bool) {
        autoSyncOnOpen = on
        UserDefaults.standard.set(on, forKey: "plaud.autoSync")
    }

    func syncInBackground(timeBudget: TimeInterval, maxRecordingBytes: Int) async -> Bool {
        guard isConfigured, !deviceAddress.isEmpty else { return false }
        await sync(address: deviceAddress, timeBudget: timeBudget,
                   maxRecordingBytes: maxRecordingBytes)
        if case .done = stage { return true }
        return false
    }

    func sync(address: String, timeBudget: TimeInterval? = nil,
              maxRecordingBytes: Int? = nil) async {
        deviceAddress = address
        try? KeychainHelper.save(key: addressKey, value: address)

        guard let creds = try? DeviceCredentials.parse(markdown: credentialsMarkdown) else {
            stage = .failed("Credentials missing or unreadable — paste plaud-credentials.md")
            return
        }
        guard let url = URL(string: endpoint), !apiKey.isEmpty else {
            stage = .failed("Transcription endpoint or API key missing")
            return
        }

        let token = creds.deviceToken ?? deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = timeBudget.map { Date().addingTimeInterval($0) }
        let client = PlaudClient(address: address, token: token, credentials: creds)
        do {
            stage = .connecting
            try await client.connect()

            stage = .authenticating
            deviceName = await client.deviceName
            _ = try await client.handshake()
            if let status = await client.batteryStatus() {
                battery = status.level
                isCharging = status.charging
            }
            try await client.timeSync()

            stage = .listing
            let sessions = try await client.getSessions()
            recordings = sessions
            guard !sessions.isEmpty else {
                stage = .failed("No recordings on the device")
                await client.disconnect()
                return
            }

            let transcriber = Transcriber(endpoint: url, apiKey: apiKey, model: model)
            var completed = 0

            for session in sessions where syncedIDs.contains(session.sessionID) {
                await client.releaseSession(session.sessionID)
            }

            for session in sessions {
                if syncedIDs.contains(session.sessionID) { continue }
                if let max = maxRecordingBytes, Int(session.fileSize) > max {
                    continue    // leave it for a window with more room
                }
                if let d = deadline, Date() >= d {
                    break       // out of time; the rest waits
                }
                stage = .downloading(0)
                let raw = try await client.downloadFileV20(
                    sessionID: session.sessionID,
                    fileSize: session.fileSize,
                    progress: { done, total in
                        Task { @MainActor in
                            self.stage = .downloading(total > 0 ? Double(done) / Double(total) : 0)
                        }
                    }
                )

                stage = .decrypting
                let frames = try PLAUDAIContainer.decryptToFrames(
                    raw, privateKeyPEM: creds.rsaPrivateKeyPEM)

                stage = .transcribing(0, 1)
                let result: Transcriber.Result
                do {
                    result = try await transcriber.transcribe(frames: frames) { done, total in
                        Task { @MainActor in self.stage = .transcribing(done, total) }
                    }
                } catch {
                    let dbg = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask)[0]
                        .appendingPathComponent("PlaudeDebug", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dbg, withIntermediateDirectories: true)
                    let stem = Self.fileName(for: session.sessionID)
                    try? raw.write(to: dbg.appendingPathComponent("\(stem).container"))
                    try? frames.write(to: dbg.appendingPathComponent("\(stem).frames"))
                    try? OggOpus.mux(frames: frames)
                        .write(to: dbg.appendingPathComponent("\(stem).ogg"))
                    throw NSError(domain: "plaude", code: 1, userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(error.localizedDescription) [container \(raw.count)B, frames \(frames.count)B — debug copy saved]"
                    ])
                }

                let title = Self.title(for: session.sessionID)
                let md = TranscriptMarkdown.render(result, title: title,
                                                   created: Date(timeIntervalSince1970: TimeInterval(session.sessionID)))
                lastTranscriptPath = try await save(markdown: md,
                                                    name: Self.fileName(for: session.sessionID),
                                                    sessionID: session.sessionID)
                markSynced(session.sessionID)
                completed += 1
            }

            battery = await client.batteryLevel() ?? battery
            recordings = (try? await client.getSessions()) ?? []
            await client.disconnect()
            let msg = "Synced \(completed) recording\(completed == 1 ? "" : "s")"
            stage = .done(msg)
            lastResultLine = "\(msg) · \(Self.clockNow())"
        } catch {
            await client.disconnect()
            stage = .failed(error.localizedDescription)
        }
    }

    private func save(markdown: String, name: String, sessionID: UInt32?) async throws -> URL? {
        if destination == "mcp" {
            guard let url = URL(string: mcpURL), !mcpToken.isEmpty else {
                throw MCPNoteClient.MCPError.http(-1, "MCP URL or token missing")
            }
            let root = vaultFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let date = sessionID.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            let day = Self.folderDay(date)
            let time = Self.folderTime(date)
            let path = root.isEmpty ? "\(day)/\(time)/\(name).md"
                                    : "\(root)/\(day)/\(time)/\(name).md"
            try await noteClient(url).writeNote(path: path, content: markdown)
            return nil
        }
        return try saveToDisk(markdown: markdown, name: name)
    }

    private func saveToDisk(markdown: String, name: String) throws -> URL {
        if let folder = resolveOutputFolder() {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let url = folder.appendingPathComponent("\(name).md")
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plaud", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func fileName(for sessionID: UInt32) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(sessionID))) + "_UTC"
    }

    static func clockNow() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date())
    }

    static func folderDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func folderTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH-mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func title(for sessionID: UInt32) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(sessionID))) + " UTC"
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
