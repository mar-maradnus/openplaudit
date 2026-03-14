/// Tests for ErrorJournal — structured JSONL error logging.

import Foundation
import Testing
@testable import SyncEngine

@Suite("Error journal")
struct ErrorJournalTests {

    private func tempJournalPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-errors-\(UUID().uuidString).jsonl")
    }

    @Test("Append and read entries")
    func appendAndRead() {
        let path = tempJournalPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let journal = ErrorJournal(path: path)
        let entry1 = ErrorEntry(
            module: "ble", operation: "connect",
            errorType: "BLEError", message: "Device not found",
            context: ["address": "ABC-123"]
        )
        let entry2 = ErrorEntry(
            module: "sync", operation: "download",
            errorType: "SyncError", message: "Timeout"
        )

        journal.append(entry1)
        journal.append(entry2)

        let entries = journal.readAll()
        #expect(entries.count == 2)
        #expect(entries[0].module == "ble")
        #expect(entries[0].operation == "connect")
        #expect(entries[0].errorType == "BLEError")
        #expect(entries[0].message == "Device not found")
        #expect(entries[0].context["address"] == "ABC-123")
        #expect(entries[1].module == "sync")
    }

    @Test("Log convenience method creates entry from Error")
    func logConvenience() {
        let path = tempJournalPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let journal = ErrorJournal(path: path)

        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "Something went wrong" }
        }

        journal.log(module: "import", operation: "convert", error: TestError(),
                     context: ["filename": "test.mp3"])

        let entries = journal.readAll()
        #expect(entries.count == 1)
        #expect(entries[0].module == "import")
        #expect(entries[0].operation == "convert")
        #expect(entries[0].errorType == "TestError")
        #expect(entries[0].message == "Something went wrong")
        #expect(entries[0].context["filename"] == "test.mp3")
    }

    @Test("Empty journal returns no entries")
    func emptyJournal() {
        let path = tempJournalPath()
        let journal = ErrorJournal(path: path)
        #expect(journal.readAll().isEmpty)
        #expect(journal.entryCount == 0)
    }

    @Test("Entry count matches appended entries")
    func entryCount() {
        let path = tempJournalPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let journal = ErrorJournal(path: path)
        journal.append(ErrorEntry(module: "a", operation: "b", errorType: "C", message: "d"))
        journal.append(ErrorEntry(module: "e", operation: "f", errorType: "G", message: "h"))
        journal.append(ErrorEntry(module: "i", operation: "j", errorType: "K", message: "l"))

        #expect(journal.entryCount == 3)
    }

    @Test("Prune removes old entries")
    func pruneOldEntries() {
        let path = tempJournalPath()
        defer { try? FileManager.default.removeItem(at: path) }

        // Write an entry with an old timestamp
        let oldTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40 * 86400))
        let recentTimestamp = ISO8601DateFormatter().string(from: Date())

        let oldEntry = ErrorEntry(timestamp: oldTimestamp, module: "old", operation: "op",
                                  errorType: "E", message: "ancient")
        let recentEntry = ErrorEntry(timestamp: recentTimestamp, module: "new", operation: "op",
                                     errorType: "E", message: "fresh")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line1 = String(data: try! encoder.encode(oldEntry), encoding: .utf8)!
        let line2 = String(data: try! encoder.encode(recentEntry), encoding: .utf8)!
        try! "\(line1)\n\(line2)\n".write(to: path, atomically: true, encoding: .utf8)

        // Create journal — prune runs on init
        let journal = ErrorJournal(path: path)
        let entries = journal.readAll()
        #expect(entries.count == 1)
        #expect(entries[0].module == "new")
    }

    @Test("ErrorEntry JSON roundtrip")
    func jsonRoundtrip() throws {
        let entry = ErrorEntry(
            timestamp: "2026-03-14T12:00:00Z",
            module: "transcription",
            operation: "transcribe",
            errorType: "TranscriptionError",
            message: "Model not loaded",
            context: ["model": "medium", "session_id": "12345"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let decoded = try JSONDecoder().decode(ErrorEntry.self, from: data)

        #expect(decoded == entry)
        #expect(decoded.context["model"] == "medium")
        #expect(decoded.context["session_id"] == "12345")
    }

    @Test("ErrorEntry coding keys use snake_case")
    func codingKeys() throws {
        let entry = ErrorEntry(
            module: "ble", operation: "connect",
            errorType: "BLEError", message: "fail"
        )
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["error_type"] != nil)
        #expect(json["errorType"] == nil)
    }
}
