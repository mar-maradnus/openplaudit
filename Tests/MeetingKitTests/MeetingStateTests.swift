/// Tests for MeetingState persistence.

import Foundation
import Testing
@testable import MeetingKit

@Suite("MeetingState")
struct MeetingStateTests {

    private func tempPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("meeting-state.json")
    }

    @MainActor
    @Test func emptyWhenNoFile() {
        let state = MeetingState(path: tempPath())
        #expect(state.allEntries.isEmpty)
    }

    @MainActor
    @Test func markRecordedAndSave() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let state = MeetingState(path: path)
        state.markRecorded(id: "test-1", appName: "Zoom", duration: 120.5, filename: "20260313_100000_UTC.wav")
        try state.saveAtomically()

        // Reload
        let state2 = MeetingState(path: path)
        let entry = state2.allEntries["test-1"]
        #expect(entry != nil)
        #expect(entry?.appName == "Zoom")
        #expect(entry?.durationSeconds == 120.5)
        #expect(entry?.filename == "20260313_100000_UTC.wav")
        #expect(entry?.recordedAt != nil)
        #expect(entry?.transcribedAt == nil)
    }

    @MainActor
    @Test func markTranscribed() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let state = MeetingState(path: path)
        state.markRecorded(id: "test-2", appName: "Teams", duration: 60, filename: "test.wav")
        state.markTranscribed(id: "test-2")
        try state.saveAtomically()

        #expect(state.isComplete("test-2"))
        #expect(!state.needsTranscription("test-2"))
    }

    @MainActor
    @Test func needsTranscription() {
        let state = MeetingState(path: tempPath())
        state.markRecorded(id: "test-3", appName: "FaceTime", duration: 30, filename: "test.wav")

        #expect(state.needsTranscription("test-3"))
        #expect(!state.isComplete("test-3"))
    }

    @MainActor
    @Test func markFailedClearedOnRecord() {
        let state = MeetingState(path: tempPath())
        state.markFailed(id: "test-4", reason: "capture error")
        #expect(state.allEntries["test-4"]?.failedAt != nil)

        state.markRecorded(id: "test-4", appName: "Zoom", duration: 10, filename: "test.wav")
        #expect(state.allEntries["test-4"]?.failedAt == nil)
        #expect(state.allEntries["test-4"]?.failureReason == nil)
    }

    @MainActor
    @Test func corruptFileReturnsEmpty() throws {
        let path = tempPath()
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "not valid json".write(to: path, atomically: true, encoding: .utf8)
        let state = MeetingState(path: path)
        #expect(state.allEntries.isEmpty)
    }
}
