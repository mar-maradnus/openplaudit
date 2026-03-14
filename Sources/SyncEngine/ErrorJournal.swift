/// Structured error journal — append-only JSONL log for support diagnostics.
///
/// Writes to ~/.local/share/openplaudit/errors.jsonl. Each line is a
/// self-contained JSON object. Entries older than 30 days are pruned on launch.
/// Survives os_log rotation (unified log rotates aggressively on macOS).

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "error-journal")

/// A single error journal entry.
public struct ErrorEntry: Codable, Sendable, Equatable {
    public let timestamp: String
    public let module: String
    public let operation: String
    public let errorType: String
    public let message: String
    public let context: [String: String]

    enum CodingKeys: String, CodingKey {
        case timestamp, module, operation
        case errorType = "error_type"
        case message, context
    }

    public init(
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        module: String,
        operation: String,
        errorType: String,
        message: String,
        context: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.module = module
        self.operation = operation
        self.errorType = errorType
        self.message = message
        self.context = context
    }
}

/// Append-only error journal backed by a JSONL file.
public final class ErrorJournal: Sendable {
    public let path: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Default journal path: ~/.local/share/openplaudit/errors.jsonl
    public static let defaultPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/openplaudit/errors.jsonl")
    }()

    /// Shared singleton for app-wide error logging.
    public static let shared = ErrorJournal()

    public init(path: URL = ErrorJournal.defaultPath) {
        self.path = path
        pruneOldEntries()
    }

    /// Append an error entry to the journal.
    public func log(
        module: String,
        operation: String,
        error: Error,
        context: [String: String] = [:]
    ) {
        let entry = ErrorEntry(
            module: module,
            operation: operation,
            errorType: String(describing: type(of: error)),
            message: error.localizedDescription,
            context: context
        )
        append(entry)
    }

    /// Append a pre-built entry.
    public func append(_ entry: ErrorEntry) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let fm = FileManager.default
            let dir = path.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let data = try encoder.encode(entry)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"

            if fm.fileExists(atPath: path.path) {
                let handle = try FileHandle(forWritingTo: path)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
            } else {
                try line.write(to: path, atomically: true, encoding: .utf8)
            }
        } catch {
            // Can't log an error about logging — just os_log it
            os.Logger(subsystem: "com.openplaudit.app", category: "error-journal")
                .error("Failed to write error journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read all entries from the journal.
    public func readAll() -> [ErrorEntry] {
        lock.lock()
        defer { lock.unlock() }

        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(ErrorEntry.self, from: Data(line.utf8))
        }
    }

    /// Prune entries older than 30 days. Called on init.
    public func pruneOldEntries(retentionDays: Int = 30) {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path),
              let text = try? String(contentsOf: path, encoding: .utf8) else { return }

        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(retentionDays) * 86400)
        )

        let lines = text.split(separator: "\n")
        let decoder = JSONDecoder()
        let kept = lines.filter { line in
            guard let entry = try? decoder.decode(ErrorEntry.self, from: Data(line.utf8)) else {
                return false
            }
            return entry.timestamp >= cutoff
        }

        if kept.count < lines.count {
            let output = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
            try? output.write(to: path, atomically: true, encoding: .utf8)
        }
    }

    /// Number of entries in the journal (for diagnostics summary).
    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }
}
