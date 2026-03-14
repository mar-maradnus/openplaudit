/// Persistent speaker store — saves and loads named speaker embeddings.
///
/// Stores each speaker as a JSON file in ~/.local/share/openplaudit/speakers/.
/// Used by the Voice Learning feature to recognise speakers across recordings.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "speaker-store")

/// Manages persistent storage of named speaker embeddings.
public final class SpeakerStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    /// Default speaker store directory.
    public static let defaultDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/openplaudit/speakers")
    }()

    public init(directory: URL = SpeakerStore.defaultDirectory) {
        self.directory = directory
    }

    /// Load all stored speaker embeddings.
    public func loadAll() -> [SpeakerEmbedding] {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        return files.compactMap { file -> SpeakerEmbedding? in
            guard file.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(SpeakerEmbedding.self, from: data)
        }
    }

    /// Save a speaker embedding. Overwrites if a speaker with the same name exists.
    public func save(_ embedding: SpeakerEmbedding) throws {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = sanitizeFilename(embedding.name) + ".json"
        let path = directory.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(embedding)
        try data.write(to: path, options: .atomic)

        log.info("Saved speaker embedding: \(embedding.name, privacy: .public)")
    }

    /// Delete a named speaker.
    public func delete(name: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let filename = sanitizeFilename(name) + ".json"
        let path = directory.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: path)

        log.info("Deleted speaker: \(name, privacy: .public)")
    }

    /// Rename a speaker.
    public func rename(from oldName: String, to newName: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let oldFilename = sanitizeFilename(oldName) + ".json"
        let oldPath = directory.appendingPathComponent(oldFilename)

        guard let data = try? Data(contentsOf: oldPath) else {
            throw SpeakerStoreError.speakerNotFound(oldName)
        }

        var embedding = try JSONDecoder().decode(SpeakerEmbedding.self, from: data)

        // Create new embedding with updated name
        let renamed = SpeakerEmbedding(name: newName, embedding: embedding.embedding)

        let newFilename = sanitizeFilename(newName) + ".json"
        let newPath = directory.appendingPathComponent(newFilename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(renamed).write(to: newPath, options: .atomic)
        try? FileManager.default.removeItem(at: oldPath)

        log.info("Renamed speaker: \(oldName, privacy: .public) → \(newName, privacy: .public)")
    }

    /// Number of stored speakers.
    public var count: Int {
        loadAll().count
    }

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return name.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }
}

/// Match diarized speakers against stored embeddings using cosine similarity.
public func matchSpeakers(
    diarizedEmbeddings: [String: [Float]],
    storedSpeakers: [SpeakerEmbedding],
    threshold: Float = 0.75
) -> [String: String] {
    var mapping: [String: String] = [:]  // "Speaker 1" → "Alice"

    for (label, embedding) in diarizedEmbeddings {
        var bestMatch: String?
        var bestSimilarity: Float = threshold

        for stored in storedSpeakers {
            let sim = cosineSimilarity(embedding, stored.embedding)
            if sim > bestSimilarity {
                bestSimilarity = sim
                bestMatch = stored.name
            }
        }

        if let match = bestMatch {
            mapping[label] = match
        }
    }

    return mapping
}

/// Apply speaker name mapping to a diarization result.
///
/// Replaces generic labels ("Speaker 1") with matched names ("Alice").
/// Unmatched speakers keep their generic labels.
public func applySpeakerNames(
    to diarization: DiarizationResult,
    mapping: [String: String]
) -> DiarizationResult {
    let updatedSegments = diarization.segments.map { seg in
        SpeakerSegment(
            start: seg.start,
            end: seg.end,
            speaker: mapping[seg.speaker] ?? seg.speaker
        )
    }
    let updatedSpeakers = diarization.speakers.map { mapping[$0] ?? $0 }
    return DiarizationResult(segments: updatedSegments, speakers: updatedSpeakers, method: diarization.method)
}

public enum SpeakerStoreError: Error, LocalizedError {
    case speakerNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .speakerNotFound(let name): return "Speaker not found: \(name)"
        }
    }
}
