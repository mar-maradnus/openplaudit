/// Import state persistence — tracks imported files and their processing status.
///
/// Follows the same pattern as MeetingState: JSON file with atomic writes,
/// corruption recovery, and phase-based lifecycle tracking.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "import-state")

public let defaultImportStatePath: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/openplaudit")
    return dir.appendingPathComponent("import-state.json")
}()

public struct ImportEntry: Codable, Equatable, Sendable {
    public var importedAt: String?
    public var transcribedAt: String?
    public var sourceFilename: String?
    public var durationSeconds: Double?
    public var filename: String?
    public var failedAt: String?
    public var failureReason: String?

    enum CodingKeys: String, CodingKey {
        case importedAt = "imported_at"
        case transcribedAt = "transcribed_at"
        case sourceFilename = "source_filename"
        case durationSeconds = "duration_seconds"
        case filename
        case failedAt = "failed_at"
        case failureReason = "failure_reason"
    }
}

public final class ImportState: @unchecked Sendable {
    public let path: URL
    private let lock = NSLock()
    private var _entries: [String: ImportEntry]

    public var entries: [String: ImportEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    public init(path: URL = defaultImportStatePath) {
        self.path = path
        self._entries = Self.loadRaw(path)
    }

    // MARK: - Persistence

    private static func loadRaw(_ path: URL) -> [String: ImportEntry] {
        guard let data = try? Data(contentsOf: path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: ImportEntry].self, from: data)
        } catch {
            log.error("Corrupt import state at \(path.path, privacy: .public), quarantining")
            quarantine(path)
            return [:]
        }
    }

    private static func quarantine(_ path: URL) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let backup = path.deletingPathExtension()
            .appendingPathExtension("corrupt_\(fmt.string(from: Date())).json")
        try? FileManager.default.moveItem(at: path, to: backup)
    }

    private func saveAtomically() {
        do {
            let dir = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(_entries)

            let tmp = path.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } catch {
            log.error("Failed to save import state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lifecycle

    public func markImported(id: String, sourceFilename: String, duration: Double, filename: String) {
        lock.lock()
        defer { lock.unlock() }
        _entries[id] = ImportEntry(
            importedAt: nowISO(),
            sourceFilename: sourceFilename,
            durationSeconds: duration,
            filename: filename
        )
        saveAtomically()
    }

    public func markTranscribed(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard _entries[id] != nil else { return }
        _entries[id]?.transcribedAt = nowISO()
        _entries[id]?.failedAt = nil
        _entries[id]?.failureReason = nil
        saveAtomically()
    }

    public func markFailed(id: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard _entries[id] != nil else { return }
        _entries[id]?.failedAt = nowISO()
        _entries[id]?.failureReason = reason
        saveAtomically()
    }

    // MARK: - Queries

    public func needsTranscription(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = _entries[id] else { return false }
        return entry.importedAt != nil && entry.transcribedAt == nil
    }

    public func isComplete(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _entries[id]?.transcribedAt != nil
    }

    public var allEntries: [String: ImportEntry] { entries }

    // MARK: - Helpers

    private func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
