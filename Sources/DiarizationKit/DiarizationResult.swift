/// Diarization result types and backend protocol.
///
/// SpeakerSegment and DiarizationResult are defined in SharedKit for
/// cross-platform use. This file re-exports them and defines the
/// backend protocol (macOS-only).

import Foundation
@_exported import SharedKit

/// Protocol for diarization backends. Implementations can be swapped
/// without changing the pipeline (model-agnostic principle).
public protocol DiarizationBackend: Sendable {
    /// Diarize audio from a 16kHz mono WAV file.
    func diarize(wavPath: URL) async throws -> DiarizationResult

    /// Human-readable name for this backend.
    var methodName: String { get }
}
