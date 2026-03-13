/// Tests for phase-aware session state tracking.
/// Ported from Python CLI `tests/test_state.py`.

import Foundation
import Testing
@testable import SyncEngine

@MainActor
private func makeState() -> SessionState {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("state.json")
    return SessionState(path: path)
}

@Suite("State roundtrip")
@MainActor
struct StateRoundtripTests {
    @Test func emptyWhenNoFile() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
        let state = SessionState(path: path)
        #expect(state.allEntries.isEmpty)
    }

    @Test func saveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = SessionState(path: path)
        state.markDownloaded(12345)
        try state.saveAtomically()

        let loaded = SessionState(path: path)
        #expect(!loaded.needsDownload(12345))
        #expect(loaded.entry(for: 12345)?["downloaded_at"] != nil)
    }

    @Test func createsParentDirs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("deep")
        let path = dir.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let state = SessionState(path: path)
        state.markDownloaded(1)
        try state.saveAtomically()
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
}

@Suite("Corrupt state recovery")
@MainActor
struct CorruptStateTests {
    @Test func corruptReturnsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{invalid json".write(to: path, atomically: true, encoding: .utf8)
        let state = SessionState(path: path)
        #expect(state.allEntries.isEmpty)
    }

    @Test func emptyFileReturnsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "".write(to: path, atomically: true, encoding: .utf8)
        let state = SessionState(path: path)
        #expect(state.allEntries.isEmpty)
    }

    @Test func corruptQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{invalid json".write(to: path, atomically: true, encoding: .utf8)
        _ = SessionState(path: path)
        // Original file should be gone (quarantined to timestamped backup)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        // A .corrupt. backup should exist in the same directory
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let backups = contents.filter { $0.lastPathComponent.contains(".corrupt.") }
        #expect(!backups.isEmpty)
    }
}

@Suite("Phase marking")
@MainActor
struct PhaseMarkingTests {
    @Test func markDownloaded() {
        let state = makeState()
        state.markDownloaded(1000)
        #expect(state.entry(for: 1000)?["downloaded_at"] != nil)
    }

    @Test func markDecoded() {
        let state = makeState()
        state.markDownloaded(1000)
        state.markDecoded(1000)
        #expect(state.entry(for: 1000)?["decoded_at"] != nil)
        #expect(state.entry(for: 1000)?["downloaded_at"] != nil)
    }

    @Test func markTranscribed() {
        let state = makeState()
        state.markDownloaded(1000)
        state.markDecoded(1000)
        state.markTranscribed(1000)
        #expect(state.entry(for: 1000)?["transcribed_at"] != nil)
    }

    @Test func markFailed() {
        let state = makeState()
        state.markDownloaded(1000)
        state.markFailed(1000, reason: "Whisper OOM")
        #expect(state.entry(for: 1000)?["failure_reason"] == "Whisper OOM")
        #expect(state.entry(for: 1000)?["failed_at"] != nil)
    }

    @Test func downloadClearsFailure() {
        let state = makeState()
        state.markFailed(1000, reason: "stall")
        state.markDownloaded(1000)
        #expect(state.entry(for: 1000)?["failed_at"] == nil)
        #expect(state.entry(for: 1000)?["failure_reason"] == nil)
    }
}

@Suite("Phase queries")
@MainActor
struct PhaseQueryTests {
    @Test func needsDownloadUnknown() {
        #expect(makeState().needsDownload(9999))
    }

    @Test func needsDownloadFalseAfter() {
        let state = makeState()
        state.markDownloaded(1000)
        #expect(!state.needsDownload(1000))
    }

    @Test func needsDecodeAfterDownload() {
        let state = makeState()
        state.markDownloaded(1000)
        #expect(state.needsDecode(1000))
    }

    @Test func needsDecodeFalseAfter() {
        let state = makeState()
        state.markDownloaded(1000)
        state.markDecoded(1000)
        #expect(!state.needsDecode(1000))
    }

    @Test func needsTranscriptionAfterDecode() {
        let state = makeState()
        state.markDownloaded(1000)
        state.markDecoded(1000)
        #expect(state.needsTranscription(1000))
    }

    @Test func needsTranscriptionFalseAfter() {
        let state = makeState()
        state.markDownloaded(1000)
        state.markDecoded(1000)
        state.markTranscribed(1000)
        #expect(!state.needsTranscription(1000))
    }

    @Test func isCompleteRequiresAll() {
        let state = makeState()
        state.markDownloaded(1000)
        #expect(!state.isComplete(1000))
        state.markDecoded(1000)
        #expect(!state.isComplete(1000))
        state.markTranscribed(1000)
        #expect(state.isComplete(1000))
    }
}

@Suite("Full lifecycle")
@MainActor
struct FullLifecycleTests {
    @Test func persistAndReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = SessionState(path: path)
        state.markDownloaded(1000)
        state.markDecoded(1000)
        state.markTranscribed(1000)
        try state.saveAtomically()

        let loaded = SessionState(path: path)
        #expect(loaded.isComplete(1000))
        #expect(!loaded.needsDownload(1000))
        #expect(!loaded.needsDecode(1000))
        #expect(!loaded.needsTranscription(1000))
    }

    @Test func failedRetryable() {
        let state = makeState()
        state.markDownloaded(1000)
        state.markFailed(1000, reason: "decode error")
        #expect(state.needsDecode(1000))
        #expect(!state.isComplete(1000))
    }

    @Test func backupAndRestore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create state with data, save twice so rolling backup contains first save
        let state = SessionState(path: path)
        state.markDownloaded(1000)
        state.markDecoded(1000)
        state.markTranscribed(1000)
        try state.saveAtomically()

        // Second save creates a rolling backup of the first
        state.markDownloaded(2000)
        try state.saveAtomically()
        #expect(state.hasBackup)

        // Corrupt the main file
        try "{broken}".write(to: path, atomically: true, encoding: .utf8)

        // Load fresh — corruption detected, starts empty
        let fresh = SessionState(path: path)
        #expect(fresh.allEntries.isEmpty)

        // Restore from rolling backup (contains state after first save)
        try fresh.restoreFromBackup()
        #expect(fresh.isComplete(1000))
    }
}
