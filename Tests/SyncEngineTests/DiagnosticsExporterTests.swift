/// Tests for DiagnosticsExporter — system info, config redaction, state summaries.

import Foundation
import Testing
@testable import SyncEngine

@Suite("Diagnostics exporter")
struct DiagnosticsExporterTests {

    @Test("System info contains expected fields")
    func systemInfo() {
        let info = DiagnosticsExporter.gatherSystemInfo()
        #expect(info.contains("OpenPlaudit Diagnostics"))
        #expect(info.contains("macOS:"))
        #expect(info.contains("Machine:"))
        #expect(info.contains("Processors:"))
        #expect(info.contains("RAM:"))
    }

    @Test("Config redaction hides token and address")
    func configRedaction() {
        var config = AppConfig()
        config.device.address = "ABCD-1234"
        config.device.token = "secret-token-value"
        config.device.name = "PLAUD Note"
        config.transcription.model = "medium"

        let redacted = DiagnosticsExporter.redactConfig(config)
        #expect(!redacted.contains("ABCD-1234"))
        #expect(!redacted.contains("secret-token-value"))
        #expect(redacted.contains("(redacted)"))
        #expect(redacted.contains("PLAUD Note"))
        #expect(redacted.contains("medium"))
    }

    @Test("Config redaction shows (empty) for empty address")
    func configRedactionEmptyAddress() {
        let config = AppConfig()
        let redacted = DiagnosticsExporter.redactConfig(config)
        #expect(redacted.contains("(empty)"))
    }

    @Test("State summary with no file")
    func stateSummaryNoFile() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let summary = DiagnosticsExporter.summariseState(path: path, name: "Test")
        #expect(summary.contains("no file or empty"))
    }

    @Test("State summary counts phases correctly")
    func stateSummaryCounts() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }

        let state: [String: [String: String]] = [
            "100": ["downloaded_at": "2026-01-01", "decoded_at": "2026-01-01", "transcribed_at": "2026-01-01"],
            "200": ["downloaded_at": "2026-01-01", "decoded_at": "2026-01-01", "transcribed_at": "2026-01-01"],
            "300": ["downloaded_at": "2026-01-01", "failed_at": "2026-01-01", "failure_reason": "timeout"],
            "400": ["downloaded_at": "2026-01-01"],
        ]

        let data = try JSONEncoder().encode(state)
        try data.write(to: path, options: .atomic)

        let summary = DiagnosticsExporter.summariseState(path: path, name: "Sync")
        #expect(summary.contains("Total sessions: 4"))
        #expect(summary.contains("Completed: 2"))
        #expect(summary.contains("Failed: 1"))
        #expect(summary.contains("Pending: 1"))
    }

    @Test("Model inventory with empty directory")
    func modelInventoryEmpty() {
        let inventory = DiagnosticsExporter.gatherModelInventory()
        // May or may not have models — just verify it doesn't crash
        #expect(!inventory.isEmpty)
    }

    @Test("Full export creates a zip file")
    func fullExport() throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        // Use a temp state path that doesn't exist (summary will say "no file")
        let fakePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-\(UUID().uuidString).json")

        let zipURL = try DiagnosticsExporter.export(
            config: AppConfig(),
            statePath: fakePath,
            meetingStatePath: fakePath,
            importStatePath: fakePath,
            to: outputDir
        )

        #expect(FileManager.default.fileExists(atPath: zipURL.path))
        #expect(zipURL.pathExtension == "zip")

        // Verify zip has some content
        let attrs = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 100)  // Non-trivial zip
    }

    @Test("Hardware model returns a non-empty string")
    func hardwareModel() {
        let model = DiagnosticsExporter.hardwareModel()
        #expect(!model.isEmpty)
    }
}
