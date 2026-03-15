/// Transcription result — cross-platform type shared between macOS and iOS.
///
/// Matches the CLI JSON format. Speaker field is optional — nil when diarization is disabled.

import Foundation

public struct TranscriptionResult: Codable, Sendable {
    public let file: String
    public let durationSeconds: Double
    public let model: String
    public let language: String
    public let segments: [Segment]
    public let text: String
    public var speakers: [String]?
    public var summary: TranscriptSummary?
    public var mindmap: String?

    /// Summary attached to a transcript by the summarisation pipeline.
    public struct TranscriptSummary: Codable, Sendable {
        public let template: String
        public let model: String
        public let content: String

        public init(template: String, model: String, content: String) {
            self.template = template
            self.model = model
            self.content = content
        }
    }

    public struct Segment: Codable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
        public var speaker: String?

        public init(start: Double, end: Double, text: String, speaker: String? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }
    }

    public init(file: String, durationSeconds: Double, model: String, language: String, segments: [Segment], text: String, speakers: [String]? = nil, summary: TranscriptSummary? = nil, mindmap: String? = nil) {
        self.file = file
        self.durationSeconds = durationSeconds
        self.model = model
        self.language = language
        self.segments = segments
        self.text = text
        self.speakers = speakers
        self.summary = summary
        self.mindmap = mindmap
    }

    enum CodingKeys: String, CodingKey {
        case file
        case durationSeconds = "duration_seconds"
        case model, language, segments, text, speakers, summary, mindmap
    }
}
