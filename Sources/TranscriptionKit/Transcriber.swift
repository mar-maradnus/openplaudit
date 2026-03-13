/// Whisper.cpp wrapper — model loading, transcription, result formatting.
///
/// Placeholder for Phase 6. Will integrate whisper.cpp SPM package.

import Foundation

/// Transcription result matching CLI JSON format.
public struct TranscriptionResult: Codable, Sendable {
    public let file: String
    public let durationSeconds: Double
    public let model: String
    public let language: String
    public let segments: [Segment]
    public let text: String

    public struct Segment: Codable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
    }

    enum CodingKeys: String, CodingKey {
        case file
        case durationSeconds = "duration_seconds"
        case model, language, segments, text
    }
}

/// Model download directory.
public let modelsDir: URL = {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/openplaudit/models")
}()

/// Placeholder transcriber. Will be replaced with whisper.cpp integration in Phase 6.
public final class Transcriber: @unchecked Sendable {
    private let modelName: String

    public init(model: String = "medium") {
        self.modelName = model
    }

    /// Transcribe a WAV file. Returns the result in CLI-compatible format.
    ///
    /// - Note: This is a placeholder. Real implementation requires whisper.cpp SPM dependency.
    public func transcribe(wavPath: URL, language: String = "en") throws -> TranscriptionResult {
        // TODO: Phase 6 — load whisper.cpp model, run inference, return segments
        return TranscriptionResult(
            file: wavPath.deletingPathExtension().lastPathComponent,
            durationSeconds: 0,
            model: modelName,
            language: language,
            segments: [],
            text: "[Transcription not yet implemented — whisper.cpp integration pending]"
        )
    }
}
