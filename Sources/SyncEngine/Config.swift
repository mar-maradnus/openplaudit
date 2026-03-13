/// Configuration management — load/save TOML, defaults, path expansion.
///
/// Ported from Python CLI `src/plaude/config.py`.

import Foundation
import TOMLKit

// MARK: - Paths

public let configDir = "~/.config/openplaudit"
public let configFilename = "config.toml"
public let defaultOutputDir = "~/Documents/OpenPlaudit"

// MARK: - Default Configuration

public struct AppConfig: Equatable, Sendable {
    public var device = DeviceConfig()
    public var output = OutputConfig()
    public var transcription = TranscriptionConfig()
    public var sync = SyncConfig()
    public var notifications = NotificationConfig()

    public struct DeviceConfig: Equatable, Sendable {
        public var address: String = ""
        public var token: String = ""
    }

    public struct OutputConfig: Equatable, Sendable {
        public var baseDir: String = defaultOutputDir
    }

    public struct TranscriptionConfig: Equatable, Sendable {
        public var model: String = "medium"
        public var language: String = "en"
    }

    public struct SyncConfig: Equatable, Sendable {
        public var autoDeleteLocalAudio: Bool = false
        public var keepRaw: Bool = false
        public var autoSyncEnabled: Bool = false
        public var autoSyncIntervalMinutes: Int = 30
    }

    public struct NotificationConfig: Equatable, Sendable {
        public var enabled: Bool = true
        public var showPreview: Bool = true
    }

    public init() {}
}

// MARK: - Config Path

public func configPath() -> URL {
    let dir = NSString(string: configDir).expandingTildeInPath
    return URL(fileURLWithPath: dir).appendingPathComponent(configFilename)
}

// MARK: - Load / Save

/// Load config from TOML file, merged with defaults. Returns defaults on missing file or parse error.
public func loadConfig(from path: URL? = nil) -> AppConfig {
    let url = path ?? configPath()
    guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }

    do {
        let text = try String(contentsOf: url, encoding: .utf8)
        let table = try TOMLTable(string: text)
        return parseConfig(table)
    } catch {
        // Quarantine corrupt file
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt")
        try? FileManager.default.moveItem(at: url, to: backup)
        return AppConfig()
    }
}

/// Save config to TOML file.
public func saveConfig(_ cfg: AppConfig, to path: URL? = nil) throws {
    let url = path ?? configPath()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let table = configToTOML(cfg)
    try table.convert(to: .toml).write(to: url, atomically: true, encoding: .utf8)
}

/// Create a default config file if one doesn't exist.
public func initConfig(at path: URL? = nil) throws -> URL {
    let url = path ?? configPath()
    if FileManager.default.fileExists(atPath: url.path) { return url }
    try saveConfig(AppConfig(), to: url)
    return url
}

/// Load config from TOML, then overlay the token from Keychain if available.
public func loadConfigWithKeychain(from path: URL? = nil) -> AppConfig {
    var cfg = loadConfig(from: path)
    if let token = KeychainHelper.load(key: "device.token"), !token.isEmpty {
        cfg.device.token = token
    }
    return cfg
}

/// Save config to TOML (without the token) and store the token in Keychain.
///
/// Keychain operations run first. If they fail, the TOML write is skipped
/// so that UI state and actual auth state cannot diverge.
public func saveConfigWithKeychain(_ cfg: AppConfig, to path: URL? = nil) throws {
    // Update Keychain first — abort entirely on failure
    if cfg.device.token.isEmpty {
        try KeychainHelper.delete(key: "device.token")
    } else {
        try KeychainHelper.save(key: "device.token", value: cfg.device.token)
    }
    // Save TOML without the token for CLI compatibility
    var tomlCfg = cfg
    tomlCfg.device.token = ""
    try saveConfig(tomlCfg, to: path)
}

// MARK: - Output Directories

public struct OutputDirs {
    public let base: URL
    public let audio: URL
    public let transcripts: URL
    public let raw: URL
}

public func getOutputDirs(_ cfg: AppConfig) -> OutputDirs {
    let base = URL(fileURLWithPath: NSString(string: cfg.output.baseDir).expandingTildeInPath)
    return OutputDirs(
        base: base,
        audio: base.appendingPathComponent("audio"),
        transcripts: base.appendingPathComponent("transcripts"),
        raw: base.appendingPathComponent("raw")
    )
}

// MARK: - TOML Parsing

private func parseConfig(_ table: TOMLTable) -> AppConfig {
    var cfg = AppConfig()

    if let device = table["device"]?.table {
        if let addr = device["address"]?.string { cfg.device.address = addr }
        if let tok = device["token"]?.string { cfg.device.token = tok }
    }

    if let output = table["output"]?.table {
        if let dir = output["base_dir"]?.string { cfg.output.baseDir = dir }
    }

    if let tx = table["transcription"]?.table {
        if let model = tx["model"]?.string { cfg.transcription.model = model }
        if let lang = tx["language"]?.string { cfg.transcription.language = lang }
    }

    if let sync = table["sync"]?.table {
        if let del = sync["auto_delete_local_audio"]?.bool { cfg.sync.autoDeleteLocalAudio = del }
        if let raw = sync["keep_raw"]?.bool { cfg.sync.keepRaw = raw }
        if let autoSync = sync["auto_sync_enabled"]?.bool { cfg.sync.autoSyncEnabled = autoSync }
        if let interval = sync["auto_sync_interval_minutes"]?.int { cfg.sync.autoSyncIntervalMinutes = interval }
    }

    if let notif = table["notifications"]?.table {
        if let en = notif["enabled"]?.bool { cfg.notifications.enabled = en }
        if let sp = notif["show_preview"]?.bool { cfg.notifications.showPreview = sp }
    }

    return cfg
}

private func configToTOML(_ cfg: AppConfig) -> TOMLTable {
    let table = TOMLTable()

    let device = TOMLTable()
    device["address"] = cfg.device.address
    device["token"] = cfg.device.token
    table["device"] = device

    let output = TOMLTable()
    output["base_dir"] = cfg.output.baseDir
    table["output"] = output

    let transcription = TOMLTable()
    transcription["model"] = cfg.transcription.model
    transcription["language"] = cfg.transcription.language
    table["transcription"] = transcription

    let sync = TOMLTable()
    sync["auto_delete_local_audio"] = cfg.sync.autoDeleteLocalAudio
    sync["keep_raw"] = cfg.sync.keepRaw
    sync["auto_sync_enabled"] = cfg.sync.autoSyncEnabled
    sync["auto_sync_interval_minutes"] = cfg.sync.autoSyncIntervalMinutes
    table["sync"] = sync

    let notifications = TOMLTable()
    notifications["enabled"] = cfg.notifications.enabled
    notifications["show_preview"] = cfg.notifications.showPreview
    table["notifications"] = notifications

    return table
}

// MARK: - Dotted Key Setter

public enum ConfigError: Error, LocalizedError {
    case invalidKeyFormat(String)
    case unknownSection(String)
    case unknownKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyFormat(let k): return "Key must be section.name, got: \(k)"
        case .unknownSection(let s): return "Unknown section: \(s)"
        case .unknownKey(let k): return "Unknown key: \(k)"
        }
    }
}

/// Set a value using dotted key notation (e.g. "device.address").
public func setNested(_ cfg: inout AppConfig, key: String, value: String) throws {
    let parts = key.split(separator: ".")
    guard parts.count == 2 else { throw ConfigError.invalidKeyFormat(key) }

    let section = String(parts[0])
    let name = String(parts[1])

    switch section {
    case "device":
        switch name {
        case "address": cfg.device.address = value
        case "token": cfg.device.token = value
        default: throw ConfigError.unknownKey(key)
        }
    case "output":
        switch name {
        case "base_dir": cfg.output.baseDir = value
        default: throw ConfigError.unknownKey(key)
        }
    case "transcription":
        switch name {
        case "model": cfg.transcription.model = value
        case "language": cfg.transcription.language = value
        default: throw ConfigError.unknownKey(key)
        }
    case "sync":
        switch name {
        case "auto_delete_local_audio": cfg.sync.autoDeleteLocalAudio = parseBool(value)
        case "keep_raw": cfg.sync.keepRaw = parseBool(value)
        case "auto_sync_enabled": cfg.sync.autoSyncEnabled = parseBool(value)
        case "auto_sync_interval_minutes": cfg.sync.autoSyncIntervalMinutes = Int(value) ?? 30
        default: throw ConfigError.unknownKey(key)
        }
    case "notifications":
        switch name {
        case "enabled": cfg.notifications.enabled = parseBool(value)
        case "show_preview": cfg.notifications.showPreview = parseBool(value)
        default: throw ConfigError.unknownKey(key)
        }
    default:
        throw ConfigError.unknownSection(section)
    }
}

private func parseBool(_ value: String) -> Bool {
    ["true", "1", "yes"].contains(value.lowercased())
}
