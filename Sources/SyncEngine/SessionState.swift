/// Session state tracker — phase-aware tracking of download/decode/transcribe.
///
/// State file: ~/.local/share/openplaudit/state.json
/// Each session progresses: downloaded_at → decoded_at → transcribed_at
///
/// Ported from Python CLI `src/plaude/state.py`.

import Foundation

public let defaultStatePath: URL = {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/openplaudit/state.json")
}()

/// Thread-safe state manager for session tracking.
public final class SessionState: @unchecked Sendable {
    private let path: URL
    private var entries: [String: [String: String]]

    public init(path: URL = defaultStatePath) {
        self.path = path
        self.entries = Self.loadRaw(path)
    }

    // MARK: - Persistence

    private static func loadRaw(_ path: URL) -> [String: [String: String]] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }

        do {
            let data = try Data(contentsOf: path)
            if data.isEmpty { return [:] }
            let decoded = try JSONDecoder().decode([String: [String: String]].self, from: data)
            return decoded
        } catch {
            // Quarantine the corrupt file
            let backup = path.deletingPathExtension().appendingPathExtension("corrupt")
            try? FileManager.default.moveItem(at: path, to: backup)
            return [:]
        }
    }

    public func save() throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try JSONEncoder.prettyPrinted.encode(entries)
        let tmp = path.deletingPathExtension().appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.moveItem(at: tmp, to: path)
    }

    /// Save state atomically, writing to .tmp then renaming to final path.
    public func saveAtomically() throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)

        // Write directly to path with atomic option (handles tmp+rename internally)
        try data.write(to: path, options: .atomic)
    }

    public func reload() {
        entries = Self.loadRaw(path)
    }

    // MARK: - Phase Marking

    private static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func getEntry(_ sessionID: UInt32) -> [String: String] {
        entries[String(sessionID)] ?? [:]
    }

    private func setEntry(_ sessionID: UInt32, _ entry: [String: String]) {
        entries[String(sessionID)] = entry
    }

    private func clearFailure(_ entry: inout [String: String]) {
        entry.removeValue(forKey: "failed_at")
        entry.removeValue(forKey: "failure_reason")
    }

    public func markDownloaded(_ sessionID: UInt32) {
        var entry = getEntry(sessionID)
        entry["downloaded_at"] = Self.nowISO()
        clearFailure(&entry)
        setEntry(sessionID, entry)
    }

    public func markDecoded(_ sessionID: UInt32) {
        var entry = getEntry(sessionID)
        entry["decoded_at"] = Self.nowISO()
        clearFailure(&entry)
        setEntry(sessionID, entry)
    }

    public func markTranscribed(_ sessionID: UInt32) {
        var entry = getEntry(sessionID)
        entry["transcribed_at"] = Self.nowISO()
        clearFailure(&entry)
        setEntry(sessionID, entry)
    }

    public func markFailed(_ sessionID: UInt32, reason: String) {
        var entry = getEntry(sessionID)
        entry["failed_at"] = Self.nowISO()
        entry["failure_reason"] = reason
        setEntry(sessionID, entry)
    }

    // MARK: - Phase Queries

    public func needsDownload(_ sessionID: UInt32) -> Bool {
        getEntry(sessionID)["downloaded_at"] == nil
    }

    public func needsDecode(_ sessionID: UInt32) -> Bool {
        let entry = getEntry(sessionID)
        return entry["downloaded_at"] != nil && entry["decoded_at"] == nil
    }

    public func needsTranscription(_ sessionID: UInt32) -> Bool {
        let entry = getEntry(sessionID)
        return entry["decoded_at"] != nil && entry["transcribed_at"] == nil
    }

    public func isComplete(_ sessionID: UInt32) -> Bool {
        getEntry(sessionID)["transcribed_at"] != nil
    }

    // MARK: - Access

    /// Raw entries for serialization/inspection.
    public var allEntries: [String: [String: String]] { entries }

    /// Entry for a specific session.
    public func entry(for sessionID: UInt32) -> [String: String]? {
        entries[String(sessionID)]
    }
}

// MARK: - JSONEncoder convenience

private extension JSONEncoder {
    static let prettyPrinted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
