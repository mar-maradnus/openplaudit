import Testing
import Foundation
@testable import ImportKit

@Suite("Import state")
struct ImportStateTests {
    private func tempPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("import-state.json")
    }

    @Test func emptyStateHasNoEntries() {
        let state = ImportState(path: tempPath())
        #expect(state.allEntries.isEmpty)
    }

    @Test func markImportedCreatesEntry() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let state = ImportState(path: path)
        state.markImported(id: "test1", sourceFilename: "recording.m4a", duration: 42.0, filename: "20260314_120000_UTC.wav")

        #expect(state.allEntries.count == 1)
        let entry = state.allEntries["test1"]
        #expect(entry?.importedAt != nil)
        #expect(entry?.sourceFilename == "recording.m4a")
        #expect(entry?.durationSeconds == 42.0)
        #expect(entry?.filename == "20260314_120000_UTC.wav")
        #expect(entry?.transcribedAt == nil)
    }

    @Test func markTranscribedUpdatesEntry() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let state = ImportState(path: path)
        state.markImported(id: "test1", sourceFilename: "test.mp3", duration: 10.0, filename: "out.wav")
        state.markTranscribed(id: "test1")

        #expect(state.allEntries["test1"]?.transcribedAt != nil)
        #expect(state.isComplete("test1"))
        #expect(!state.needsTranscription("test1"))
    }

    @Test func needsTranscriptionAfterImport() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let state = ImportState(path: path)
        state.markImported(id: "test1", sourceFilename: "test.mp3", duration: 10.0, filename: "out.wav")

        #expect(state.needsTranscription("test1"))
        #expect(!state.isComplete("test1"))
    }

    @Test func markFailedRecordsReason() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let state = ImportState(path: path)
        state.markImported(id: "test1", sourceFilename: "test.mp3", duration: 10.0, filename: "out.wav")
        state.markFailed(id: "test1", reason: "Model not found")

        let entry = state.allEntries["test1"]
        #expect(entry?.failedAt != nil)
        #expect(entry?.failureReason == "Model not found")
    }

    @Test func transcriptionClearsFailure() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let state = ImportState(path: path)
        state.markImported(id: "test1", sourceFilename: "test.mp3", duration: 10.0, filename: "out.wav")
        state.markFailed(id: "test1", reason: "Timeout")
        state.markTranscribed(id: "test1")

        let entry = state.allEntries["test1"]
        #expect(entry?.failedAt == nil)
        #expect(entry?.failureReason == nil)
        #expect(entry?.transcribedAt != nil)
    }

    @Test func statePersistsToFile() {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let state1 = ImportState(path: path)
        state1.markImported(id: "persist1", sourceFilename: "a.wav", duration: 5.0, filename: "out.wav")
        state1.markTranscribed(id: "persist1")

        // Reload from disk
        let state2 = ImportState(path: path)
        #expect(state2.allEntries.count == 1)
        #expect(state2.isComplete("persist1"))
        #expect(state2.allEntries["persist1"]?.sourceFilename == "a.wav")
    }

    @Test func corruptFileIsQuarantined() throws {
        let path = tempPath()
        let dir = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: path, atomically: true, encoding: .utf8)

        let state = ImportState(path: path)
        #expect(state.allEntries.isEmpty) // corrupt data discarded

        // Original file should be quarantined (moved to .corrupt_*.json)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let corruptFiles = files.filter { $0.lastPathComponent.contains("corrupt") }
        #expect(!corruptFiles.isEmpty)
    }

    @Test func unknownIdQueriesReturnFalse() {
        let state = ImportState(path: tempPath())
        #expect(!state.needsTranscription("nonexistent"))
        #expect(!state.isComplete("nonexistent"))
    }
}
