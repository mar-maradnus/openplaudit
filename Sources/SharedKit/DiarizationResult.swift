/// Diarization result types — cross-platform types shared between macOS and iOS.
///
/// Speaker-labelled time segments used by all diarization backends.

import Foundation

/// A time segment assigned to a speaker.
public struct SpeakerSegment: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }

    public var duration: Double { end - start }
}

/// Full diarization result for a recording.
public struct DiarizationResult: Codable, Equatable, Sendable {
    public let segments: [SpeakerSegment]
    public let speakers: [String]
    public let method: String

    public init(segments: [SpeakerSegment], speakers: [String], method: String) {
        self.segments = segments
        self.speakers = speakers
        self.method = method
    }
}
