/// Diarization result types — speaker-labelled time segments.
///
/// These types are shared across all diarization backends (energy-based,
/// MFCC+clustering, ONNX/pyannote). The pipeline interface is backend-agnostic.

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

/// Protocol for diarization backends. Implementations can be swapped
/// without changing the pipeline (model-agnostic principle).
public protocol DiarizationBackend: Sendable {
    /// Diarize audio from a 16kHz mono WAV file.
    func diarize(wavPath: URL) async throws -> DiarizationResult

    /// Human-readable name for this backend.
    var methodName: String { get }
}
