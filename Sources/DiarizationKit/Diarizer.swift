/// Speaker diarization engine — the main entry point.
///
/// Loads 16kHz mono WAV, extracts MFCC features, clusters speakers,
/// and merges labels with Whisper transcript segments.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "diarization")

/// MFCC + spectral clustering diarization backend.
/// Uses Accelerate framework only — no external dependencies.
public final class MFCCDiarizer: DiarizationBackend, @unchecked Sendable {
    public let methodName = "mfcc-clustering"

    private let maxSpeakers: Int

    public init(maxSpeakers: Int = 6) {
        self.maxSpeakers = maxSpeakers
    }

    public func diarize(wavPath: URL) async throws -> DiarizationResult {
        log.info("Diarizing \(wavPath.lastPathComponent, privacy: .public)")

        let samples = try loadWAVAsFloat(wavPath)
        guard samples.count > 16000 else {
            // Less than 1 second — single speaker
            let duration = Double(samples.count) / 16000.0
            return DiarizationResult(
                segments: [SpeakerSegment(start: 0, end: duration, speaker: "Speaker 1")],
                speakers: ["Speaker 1"],
                method: methodName
            )
        }

        // Extract MFCC features
        let mfccs = extractMFCC(samples: samples)
        guard !mfccs.isEmpty else {
            let duration = Double(samples.count) / 16000.0
            return DiarizationResult(
                segments: [SpeakerSegment(start: 0, end: duration, speaker: "Speaker 1")],
                speakers: ["Speaker 1"],
                method: methodName
            )
        }

        // Cluster into speakers
        let labels = clusterSpeakers(features: mfccs, maxSpeakers: maxSpeakers)
        let segments = labelsToSegments(labels: labels)
        let speakers = Set(segments.map(\.speaker)).sorted()

        log.info("Diarization complete: \(speakers.count) speakers, \(segments.count) segments")

        return DiarizationResult(segments: segments, speakers: speakers, method: methodName)
    }
}

/// Merge diarization speaker labels into Whisper transcript segments.
///
/// For each transcript segment, finds the overlapping diarization segment
/// with the most overlap and assigns that speaker label.
public func mergeTranscriptWithSpeakers(
    transcriptSegments: [(start: Double, end: Double, text: String)],
    diarization: DiarizationResult
) -> [(start: Double, end: Double, text: String, speaker: String)] {
    transcriptSegments.map { seg in
        let speaker = findOverlappingSpeaker(
            start: seg.start,
            end: seg.end,
            diarizationSegments: diarization.segments
        )
        return (seg.start, seg.end, seg.text, speaker)
    }
}

/// Find the speaker with the most overlap for a given time range.
func findOverlappingSpeaker(
    start: Double,
    end: Double,
    diarizationSegments: [SpeakerSegment]
) -> String {
    var bestSpeaker = "Speaker 1"
    var bestOverlap: Double = 0

    for seg in diarizationSegments {
        let overlapStart = max(start, seg.start)
        let overlapEnd = min(end, seg.end)
        let overlap = max(0, overlapEnd - overlapStart)
        if overlap > bestOverlap {
            bestOverlap = overlap
            bestSpeaker = seg.speaker
        }
    }

    return bestSpeaker
}

// MARK: - WAV Loading

enum DiarizationError: Error, LocalizedError {
    case invalidWAV(String)

    var errorDescription: String? {
        switch self {
        case .invalidWAV(let reason): return "Invalid WAV for diarization: \(reason)"
        }
    }
}

/// Load a 16kHz mono 16-bit WAV file as Float32 samples.
func loadWAVAsFloat(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else {
        throw DiarizationError.invalidWAV("File too small")
    }

    // Verify RIFF header
    let riff = String(data: data[0..<4], encoding: .ascii)
    let wave = String(data: data[8..<12], encoding: .ascii)
    guard riff == "RIFF", wave == "WAVE" else {
        throw DiarizationError.invalidWAV("Not a WAV file")
    }

    // Find data chunk
    var offset = 12
    while offset + 8 < data.count {
        let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
        let chunkSize = data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
        }
        if chunkID == "data" {
            let dataStart = offset + 8
            let dataEnd = min(dataStart + Int(chunkSize), data.count)
            let pcmData = data[dataStart..<dataEnd]

            // Convert Int16 LE to Float32
            let sampleCount = pcmData.count / 2
            var samples = [Float](repeating: 0, count: sampleCount)
            pcmData.withUnsafeBytes { raw in
                let int16s = raw.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    samples[i] = Float(int16s[i]) / 32768.0
                }
            }
            return samples
        }
        offset += 8 + Int(chunkSize)
        if chunkSize % 2 != 0 { offset += 1 } // WAV chunks are 2-byte aligned
    }

    throw DiarizationError.invalidWAV("No data chunk found")
}
