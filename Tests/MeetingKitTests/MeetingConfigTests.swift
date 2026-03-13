/// Tests for meeting config TOML round-trip.

import Foundation
import Testing
@testable import SyncEngine

@Suite("MeetingConfig")
struct MeetingConfigTests {

    @Test func defaultMeetingConfig() {
        let cfg = AppConfig()
        #expect(cfg.meeting.enabled == false)
        #expect(cfg.meeting.autoRecord == false)
        #expect(cfg.meeting.consentAcknowledged == false)
        #expect(cfg.meeting.includeBrowsers == false)
        #expect(cfg.meeting.micDeviceID == "")
        #expect(cfg.meeting.monitoredApps.contains("us.zoom.xos"))
        #expect(cfg.meeting.monitoredApps.contains("com.apple.FaceTime"))
    }

    @Test func meetingConfigRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        var cfg = AppConfig()
        cfg.meeting.enabled = true
        cfg.meeting.autoRecord = true
        cfg.meeting.monitoredApps = ["us.zoom.xos", "com.apple.FaceTime"]
        cfg.meeting.includeBrowsers = true
        cfg.meeting.micDeviceID = "BuiltInMic"
        cfg.meeting.consentAcknowledged = true

        try saveConfig(cfg, to: path)
        let loaded = loadConfig(from: path)

        #expect(loaded.meeting.enabled == true)
        #expect(loaded.meeting.autoRecord == true)
        #expect(loaded.meeting.monitoredApps == ["us.zoom.xos", "com.apple.FaceTime"])
        #expect(loaded.meeting.includeBrowsers == true)
        #expect(loaded.meeting.micDeviceID == "BuiltInMic")
        #expect(loaded.meeting.consentAcknowledged == true)
    }

    @Test func meetingConfigPreservesOtherSections() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        var cfg = AppConfig()
        cfg.device.address = "MY-DEVICE-UUID"
        cfg.meeting.enabled = true

        try saveConfig(cfg, to: path)
        let loaded = loadConfig(from: path)

        #expect(loaded.device.address == "MY-DEVICE-UUID")
        #expect(loaded.meeting.enabled == true)
        #expect(loaded.transcription.model == "medium")
    }

    @Test func setNestedMeetingFields() throws {
        var cfg = AppConfig()
        try setNested(&cfg, key: "meeting.enabled", value: "true")
        #expect(cfg.meeting.enabled == true)

        try setNested(&cfg, key: "meeting.auto_record", value: "true")
        #expect(cfg.meeting.autoRecord == true)

        try setNested(&cfg, key: "meeting.mic_device_id", value: "TestMic")
        #expect(cfg.meeting.micDeviceID == "TestMic")
    }

    @Test func setNestedRejectsUnknownMeetingKey() {
        var cfg = AppConfig()
        #expect(throws: ConfigError.self) {
            try setNested(&cfg, key: "meeting.bogus", value: "val")
        }
    }

    @Test func meetingOutputDirs() {
        var cfg = AppConfig()
        cfg.output.baseDir = "/tmp/plaude_test"
        let dirs = getOutputDirs(cfg)
        #expect(dirs.meetingAudio.path == "/tmp/plaude_test/meetings/audio")
        #expect(dirs.meetingTranscripts.path == "/tmp/plaude_test/meetings/transcripts")
    }
}
