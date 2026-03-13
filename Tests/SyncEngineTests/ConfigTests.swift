/// Tests for config load/save/defaults.
/// Ported from Python CLI `tests/test_config.py`.

import Foundation
import Testing
@testable import SyncEngine

@Suite("loadConfig")
struct LoadConfigTests {
    @Test func defaultsWhenNoFile() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nonexistent.toml")
        let cfg = loadConfig(from: path)
        #expect(cfg.device.address == "")
        #expect(cfg.transcription.model == "medium")
    }

    @Test func loadsAndMerges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        var cfg = AppConfig()
        cfg.device.address = "AA:BB:CC"
        cfg.device.token = "tok123"
        try saveConfig(cfg, to: path)

        let loaded = loadConfig(from: path)
        #expect(loaded.device.address == "AA:BB:CC")
        #expect(loaded.device.token == "tok123")
        #expect(loaded.transcription.model == "medium")
        #expect(loaded.notifications.enabled == true)
    }
}

@Suite("Corrupt config recovery")
struct CorruptConfigTests {
    @Test func corruptReturnsDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "this is not [valid toml".write(to: path, atomically: true, encoding: .utf8)
        let cfg = loadConfig(from: path)
        #expect(cfg.device.address == "")
        #expect(cfg.transcription.model == "medium")
    }

    @Test func corruptQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "this is not [valid toml".write(to: path, atomically: true, encoding: .utf8)
        _ = loadConfig(from: path)
        let corruptPath = path.deletingPathExtension().appendingPathExtension("corrupt")
        #expect(FileManager.default.fileExists(atPath: corruptPath.path))
    }
}

@Suite("saveConfig")
struct SaveConfigTests {
    @Test func createsParentDirs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("deep")
            .appendingPathComponent("nested")
        let path = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }

        try saveConfig(AppConfig(), to: path)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test func roundtrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = AppConfig()
        try saveConfig(original, to: path)
        let loaded = loadConfig(from: path)
        #expect(loaded == original)
    }
}

@Suite("initConfig")
struct InitConfigTests {
    @Test func createsWithDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try initConfig(at: path)
        #expect(FileManager.default.fileExists(atPath: result.path))
        let cfg = loadConfig(from: result)
        #expect(cfg == AppConfig())
    }

    @Test func doesNotOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        var custom = AppConfig()
        custom.device.address = "MY_DEVICE"
        try saveConfig(custom, to: path)

        _ = try initConfig(at: path)
        let cfg = loadConfig(from: path)
        #expect(cfg.device.address == "MY_DEVICE")
    }
}

@Suite("setNested")
struct SetNestedTests {
    @Test func setsString() throws {
        var cfg = AppConfig()
        try setNested(&cfg, key: "device.address", value: "NEW_ADDR")
        #expect(cfg.device.address == "NEW_ADDR")
    }

    @Test func coercesBool() throws {
        var cfg = AppConfig()
        try setNested(&cfg, key: "sync.keep_raw", value: "true")
        #expect(cfg.sync.keepRaw == true)
    }

    @Test func rejectsUnknownSection() {
        var cfg = AppConfig()
        #expect(throws: ConfigError.self) {
            try setNested(&cfg, key: "bogus.key", value: "val")
        }
    }

    @Test func rejectsUnknownKey() {
        var cfg = AppConfig()
        #expect(throws: ConfigError.self) {
            try setNested(&cfg, key: "device.bogus", value: "val")
        }
    }

    @Test func rejectsBadFormat() {
        var cfg = AppConfig()
        #expect(throws: ConfigError.self) {
            try setNested(&cfg, key: "just_one_part", value: "val")
        }
    }
}

@Suite("getOutputDirs")
struct OutputDirsTests {
    @Test func expectedSubdirs() {
        var cfg = AppConfig()
        cfg.output.baseDir = "/tmp/plaude_test"
        let dirs = getOutputDirs(cfg)
        #expect(dirs.base.path == "/tmp/plaude_test")
        #expect(dirs.audio.path == "/tmp/plaude_test/audio")
        #expect(dirs.transcripts.path == "/tmp/plaude_test/transcripts")
        #expect(dirs.raw.path == "/tmp/plaude_test/raw")
    }
}
