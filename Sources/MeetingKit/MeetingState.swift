/// Persistent state for meeting recordings.
///
/// Stores meeting metadata in ~/.local/share/openplaudit/meeting-state.json.
/// Loaded on launch to populate recent meetings list. Atomic writes with
/// rolling backup, same pattern as SessionState.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "meeting-state")

public let defaultMeetingStatePath: URL = {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/openplaudit/meeting-state.json")
}()

/// A single meeting recording entry.
public struct MeetingEntry: Codable, Equatable, Sendable {
    public var recordedAt: String?
    public var transcribedAt: String?
    public var appName: String?
    public var durationSeconds: Double?
    public var filename: String?
    public var failedAt: String?
    public var failureReason: String?

    enum CodingKeys: String, CodingKey {
        case recordedAt = "recorded_at"
        case transcribedAt = "transcribed_at"
        case appName = "app_name"
        case durationSeconds = "duration_seconds"
        case filename
        case failedAt = "failed_at"
        case failureReason = "failure_reason"
    }
}

/// Persistent meeting state manager.
@MainActor
public final class MeetingState {
    private let path: URL
    private var entries: [String: MeetingEntry]

    public init(path: URL = defaultMeetingStatePath) {
        self.path = path
        self.entries = Self.loadRaw(path)
    }

    // MARK: - Persistence

    private static func loadRaw(_ path: URL) -> [String: MeetingEntry] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        do {
            let data = try Data(contentsOf: path)
            if data.isEmpty { return [:] }
            return try JSONDecoder().decode([String: MeetingEntry].self, from: data)
        } catch {
            log.error("Corrupt meeting state: \(error.localizedDescription, privacy: .public)")
            quarantine(path)
            return [:]
        }
    }

    private static func quarantine(_ path: URL) {
        let fm = FileManager.default
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let backupName = "meeting-state.corrupt.\(ts).json"
        let backupURL = path.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            try fm.moveItem(at: path, to: backupURL)
        } catch {
            try? fm.removeItem(at: path)
        }
    }

    public func saveAtomically() throws {
        let dir = path.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Rolling backup
        if fm.fileExists(atPath: path.path) {
            let backupPath = path.deletingPathExtension().appendingPathExtension("backup.json")
            try? fm.removeItem(at: backupPath)
            try? fm.copyItem(at: path, to: backupPath)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: path, options: .atomic)
    }

    // MARK: - Record lifecycle

    /// Record a completed meeting.
    public func markRecorded(id: String, appName: String, duration: Double, filename: String) {
        var entry = entries[id] ?? MeetingEntry()
        entry.recordedAt = Self.nowISO()
        entry.appName = appName
        entry.durationSeconds = duration
        entry.filename = filename
        entry.failedAt = nil
        entry.failureReason = nil
        entries[id] = entry
    }

    /// Mark a meeting as transcribed.
    public func markTranscribed(id: String) {
        var entry = entries[id] ?? MeetingEntry()
        entry.transcribedAt = Self.nowISO()
        entry.failedAt = nil
        entry.failureReason = nil
        entries[id] = entry
    }

    /// Mark a meeting as failed.
    public func markFailed(id: String, reason: String) {
        var entry = entries[id] ?? MeetingEntry()
        entry.failedAt = Self.nowISO()
        entry.failureReason = reason
        entries[id] = entry
    }

    // MARK: - Queries

    public func needsTranscription(_ id: String) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.recordedAt != nil && entry.transcribedAt == nil
    }

    public func isComplete(_ id: String) -> Bool {
        entries[id]?.transcribedAt != nil
    }

    /// All entries for rebuilding the recent meetings list.
    public var allEntries: [String: MeetingEntry] { entries }

    // MARK: - Helpers

    private static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
