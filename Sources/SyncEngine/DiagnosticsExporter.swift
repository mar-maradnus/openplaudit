/// Diagnostics exporter — bundles support information into a zip file.
///
/// Collects: os_log output, redacted config, state summaries, system info,
/// model inventory, and the error journal. Nothing is sent automatically;
/// the user chooses where to save the zip.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "diagnostics")

/// Collects diagnostic information and writes a zip to the given URL.
public struct DiagnosticsExporter {

    private static let defaultMeetingStatePath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/openplaudit/meeting-state.json")
    }()

    private static let defaultImportStatePath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/openplaudit/import-state.json")
    }()

    /// Export a diagnostics zip to the given directory. Returns the zip URL.
    public static func export(
        config: AppConfig,
        statePath: URL = defaultStatePath,
        meetingStatePath: URL? = nil,
        importStatePath: URL? = nil,
        errorJournalPath: URL = ErrorJournal.defaultPath,
        to outputDir: URL
    ) throws -> URL {
        let meetingStatePath = meetingStatePath ?? Self.defaultMeetingStatePath
        let importStatePath = importStatePath ?? Self.defaultImportStatePath
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("openplaudit-diag-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        defer { try? fm.removeItem(at: tmpDir) }

        // 1. System info
        let sysInfo = gatherSystemInfo()
        try sysInfo.write(to: tmpDir.appendingPathComponent("system-info.txt"), atomically: true, encoding: .utf8)

        // 2. Redacted config
        let redactedConfig = redactConfig(config)
        try redactedConfig.write(to: tmpDir.appendingPathComponent("config-redacted.txt"), atomically: true, encoding: .utf8)

        // 3. State summaries
        let stateSummary = summariseState(path: statePath, name: "PLAUD sync")
        try stateSummary.write(to: tmpDir.appendingPathComponent("state-summary.txt"), atomically: true, encoding: .utf8)

        let meetingSummary = summariseJSON(path: meetingStatePath, name: "Meeting")
        try meetingSummary.write(to: tmpDir.appendingPathComponent("meeting-state-summary.txt"), atomically: true, encoding: .utf8)

        let importSummary = summariseJSON(path: importStatePath, name: "Import")
        try importSummary.write(to: tmpDir.appendingPathComponent("import-state-summary.txt"), atomically: true, encoding: .utf8)

        // 4. Model inventory
        let modelInventory = gatherModelInventory()
        try modelInventory.write(to: tmpDir.appendingPathComponent("models.txt"), atomically: true, encoding: .utf8)

        // 5. Error journal (copy verbatim)
        if fm.fileExists(atPath: errorJournalPath.path) {
            try fm.copyItem(at: errorJournalPath, to: tmpDir.appendingPathComponent("errors.jsonl"))
        }

        // 6. os_log (last 24 hours, filtered to our subsystem)
        let osLogOutput = captureOSLog()
        try osLogOutput.write(to: tmpDir.appendingPathComponent("os_log.txt"), atomically: true, encoding: .utf8)

        // Create zip
        let timestamp = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd_HHmmss"
            return fmt.string(from: Date())
        }()
        let zipName = "openplaudit-diagnostics-\(timestamp).zip"
        let zipPath = outputDir.appendingPathComponent(zipName)

        try createZip(from: tmpDir, to: zipPath)

        log.info("Diagnostics exported to \(zipPath.path, privacy: .public)")
        return zipPath
    }

    // MARK: - Collectors

    static func gatherSystemInfo() -> String {
        var lines: [String] = []
        lines.append("OpenPlaudit Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // App version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        lines.append("App Version: \(version) (\(build))")

        // macOS version
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        // Hardware
        lines.append("Machine: \(hardwareModel())")
        lines.append("Processors: \(ProcessInfo.processInfo.processorCount)")
        lines.append("RAM: \(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) GB")

        // Disk space
        if let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64 {
            lines.append("Free Disk: \(free / (1024 * 1024 * 1024)) GB")
        }

        return lines.joined(separator: "\n")
    }

    static func redactConfig(_ config: AppConfig) -> String {
        var lines: [String] = []
        lines.append("[device]")
        lines.append("address = \"\(config.device.address.isEmpty ? "(empty)" : "(redacted)")\"")
        lines.append("token = \"(redacted)\"")
        lines.append("name = \"\(config.device.name)\"")
        lines.append("")
        lines.append("[output]")
        lines.append("base_dir = \"\(config.output.baseDir)\"")
        lines.append("")
        lines.append("[transcription]")
        lines.append("model = \"\(config.transcription.model)\"")
        lines.append("language = \"\(config.transcription.language)\"")
        lines.append("")
        lines.append("[sync]")
        lines.append("auto_delete_local_audio = \(config.sync.autoDeleteLocalAudio)")
        lines.append("keep_raw = \(config.sync.keepRaw)")
        lines.append("auto_sync_enabled = \(config.sync.autoSyncEnabled)")
        lines.append("auto_sync_interval_minutes = \(config.sync.autoSyncIntervalMinutes)")
        lines.append("")
        lines.append("[notifications]")
        lines.append("enabled = \(config.notifications.enabled)")
        lines.append("show_preview = \(config.notifications.showPreview)")
        lines.append("")
        lines.append("[diarization]")
        lines.append("enabled = \(config.diarization.enabled)")
        lines.append("max_speakers = \(config.diarization.maxSpeakers)")
        lines.append("")
        lines.append("[summarisation]")
        lines.append("enabled = \(config.summarisation.enabled)")
        lines.append("model = \"\(config.summarisation.model)\"")
        lines.append("default_template = \"\(config.summarisation.defaultTemplate)\"")
        lines.append("ollama_url = \"\(config.summarisation.ollamaURL)\"")
        lines.append("")
        lines.append("[meeting]")
        lines.append("enabled = \(config.meeting.enabled)")
        lines.append("auto_record = \(config.meeting.autoRecord)")
        lines.append("include_browsers = \(config.meeting.includeBrowsers)")
        lines.append("consent_acknowledged = \(config.meeting.consentAcknowledged)")
        lines.append("monitored_apps = [\(config.meeting.monitoredApps.map { "\"\($0)\"" }.joined(separator: ", "))]")
        return lines.joined(separator: "\n")
    }

    static func summariseState(path: URL, name: String) -> String {
        guard let data = try? Data(contentsOf: path),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return "\(name) state: no file or empty"
        }

        let total = dict.count
        let completed = dict.values.filter { $0["transcribed_at"] != nil }.count
        let failed = dict.values.filter { $0["failed_at"] != nil }.count
        let pending = total - completed - failed

        return """
        \(name) State Summary
        Total sessions: \(total)
        Completed: \(completed)
        Failed: \(failed)
        Pending: \(pending)
        """
    }

    static func summariseJSON(path: URL, name: String) -> String {
        guard let data = try? Data(contentsOf: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "\(name) state: no file or empty"
        }

        return "\(name) State Summary\nTotal entries: \(dict.count)"
    }

    static func gatherModelInventory() -> String {
        let modelsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/openplaudit/models")
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(at: modelsPath, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return "Models directory: not found or empty"
        }

        if files.isEmpty { return "Models directory: empty" }

        var lines = ["Model Inventory:"]
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .short

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                let size = attrs.fileSize ?? 0
                let date = attrs.contentModificationDate.map { dateFmt.string(from: $0) } ?? "unknown"
                let sizeMB = Double(size) / 1_048_576.0
                lines.append(String(format: "  %@ — %.0f MB — %@", file.lastPathComponent, sizeMB, date))
            }
        }

        return lines.joined(separator: "\n")
    }

    static func captureOSLog() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--predicate", "subsystem == 'com.openplaudit.app'",
            "--last", "24h",
            "--style", "compact"
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? "(no output)"
        } catch {
            return "(failed to capture os_log: \(error.localizedDescription))"
        }
    }

    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    // MARK: - Zip

    static func createZip(from sourceDir: URL, to zipPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", sourceDir.path, zipPath.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DiagnosticsError.zipFailed(process.terminationStatus)
        }
    }
}

public enum DiagnosticsError: Error, LocalizedError {
    case zipFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .zipFailed(let code): return "Failed to create diagnostics zip (exit code \(code))"
        }
    }
}
