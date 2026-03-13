/// Session state tracker — phase-aware tracking of download/decode/transcribe.
///
/// State file: ~/.local/share/openplaudit/state.json
/// Each session progresses: downloaded_at → decoded_at → transcribed_at
///
/// Ported from Python CLI `src/plaude/state.py`.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "state")

public let defaultStatePath: URL = {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/openplaudit/state.json")
}()

/// State manager for session tracking. All access must be from MainActor.
@MainActor
public final class SessionState {
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
            log.error("Corrupt state file at \(path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            quarantine(path)
            return [:]
        }
    }

    /// Move a corrupt file to a timestamped backup, keeping up to 3 backups.
    private static func quarantine(_ path: URL) {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        let stem = path.deletingPathExtension().lastPathComponent

        // Create timestamped backup name: state.corrupt.20260313T143022
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let backupName = "\(stem).corrupt.\(ts).json"
        let backupURL = dir.appendingPathComponent(backupName)

        do {
            try fm.moveItem(at: path, to: backupURL)
            log.warning("Quarantined corrupt state to \(backupName, privacy: .public)")
        } catch {
            // Last resort: delete the corrupt file so we can start fresh
            try? fm.removeItem(at: path)
            log.error("Failed to quarantine, removed corrupt state file")
        }

        // Prune old backups: keep only the 3 most recent
        pruneBackups(in: dir, stem: stem, keep: 3)
    }

    private static func pruneBackups(in dir: URL, stem: String, keep: Int) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        let backups = contents
            .filter { $0.lastPathComponent.hasPrefix("\(stem).corrupt.") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for old in backups.dropFirst(keep) {
            try? fm.removeItem(at: old)
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

    /// Save state atomically, keeping a rolling backup of the previous good state.
    public func saveAtomically() throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)

        // Keep a backup of the previous good state before overwriting
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            let backupPath = path.deletingPathExtension().appendingPathExtension("backup.json")
            try? fm.removeItem(at: backupPath)
            try? fm.copyItem(at: path, to: backupPath)
        }

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

    // MARK: - Backup & Restore

    /// The rolling backup URL (last known good state before the most recent save).
    public var backupURL: URL {
        path.deletingPathExtension().appendingPathExtension("backup.json")
    }

    /// Whether a rolling backup of last-good state exists.
    public var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    /// Restore state from the rolling backup (last known good state).
    public func restoreFromBackup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path) else {
            throw StateError.backupNotFound(backupURL.lastPathComponent)
        }

        let data = try Data(contentsOf: backupURL)
        let restored = try JSONDecoder().decode([String: [String: String]].self, from: data)

        entries = restored
        try saveAtomically()
        log.info("State restored from rolling backup")
    }
}

// MARK: - State Errors

public enum StateError: Error, LocalizedError {
    case backupNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .backupNotFound(let name): return "Backup not found: \(name)"
        }
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
