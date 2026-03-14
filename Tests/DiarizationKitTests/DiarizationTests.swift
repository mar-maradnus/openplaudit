import Testing
import Foundation
@testable import DiarizationKit

@Suite("Diarization result types")
struct DiarizationResultTests {
    @Test func speakerSegmentDuration() {
        let seg = SpeakerSegment(start: 1.0, end: 3.5, speaker: "Speaker 1")
        #expect(seg.duration == 2.5)
    }

    @Test func resultEncodesAsJSON() throws {
        let result = DiarizationResult(
            segments: [
                SpeakerSegment(start: 0, end: 5.0, speaker: "Speaker 1"),
                SpeakerSegment(start: 5.0, end: 10.0, speaker: "Speaker 2"),
            ],
            speakers: ["Speaker 1", "Speaker 2"],
            method: "mfcc-clustering"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DiarizationResult.self, from: data)
        #expect(decoded == result)
    }

    @Test func emptyResultIsValid() {
        let result = DiarizationResult(segments: [], speakers: [], method: "test")
        #expect(result.segments.isEmpty)
        #expect(result.speakers.isEmpty)
    }
}

@Suite("Speaker overlap matching")
struct OverlapTests {
    @Test func exactOverlapMatchesSpeaker() {
        let segments = [
            SpeakerSegment(start: 0, end: 5, speaker: "Speaker 1"),
            SpeakerSegment(start: 5, end: 10, speaker: "Speaker 2"),
        ]
        #expect(findOverlappingSpeaker(start: 0, end: 5, diarizationSegments: segments) == "Speaker 1")
        #expect(findOverlappingSpeaker(start: 5, end: 10, diarizationSegments: segments) == "Speaker 2")
    }

    @Test func partialOverlapPicksMajority() {
        let segments = [
            SpeakerSegment(start: 0, end: 5, speaker: "Speaker 1"),
            SpeakerSegment(start: 5, end: 10, speaker: "Speaker 2"),
        ]
        // 3-7: 2s overlap with Speaker 1 (3-5), 2s with Speaker 2 (5-7) → tie, first wins
        let speaker = findOverlappingSpeaker(start: 3, end: 7, diarizationSegments: segments)
        #expect(speaker == "Speaker 1" || speaker == "Speaker 2")

        // 1-8: 4s overlap with Speaker 1 (1-5), 3s with Speaker 2 (5-8) → Speaker 1
        #expect(findOverlappingSpeaker(start: 1, end: 8, diarizationSegments: segments) == "Speaker 1")
    }

    @Test func noOverlapDefaultsToSpeaker1() {
        let segments = [
            SpeakerSegment(start: 10, end: 20, speaker: "Speaker 2"),
        ]
        #expect(findOverlappingSpeaker(start: 0, end: 5, diarizationSegments: segments) == "Speaker 1")
    }

    @Test func mergeTranscriptAppliesSpeakers() {
        let transcript = [
            (start: 0.0, end: 3.0, text: "Hello"),
            (start: 3.0, end: 6.0, text: "Hi there"),
            (start: 6.0, end: 9.0, text: "How are you"),
        ]
        let diarization = DiarizationResult(
            segments: [
                SpeakerSegment(start: 0, end: 4, speaker: "Speaker 1"),
                SpeakerSegment(start: 4, end: 10, speaker: "Speaker 2"),
            ],
            speakers: ["Speaker 1", "Speaker 2"],
            method: "test"
        )
        let merged = mergeTranscriptWithSpeakers(transcriptSegments: transcript, diarization: diarization)
        #expect(merged[0].speaker == "Speaker 1")  // 0-3: fully in S1 (0-4)
        #expect(merged[1].speaker == "Speaker 2")  // 3-6: 1s S1 (3-4), 2s S2 (4-6) → Speaker 2
        #expect(merged[2].speaker == "Speaker 2")  // 6-9: fully in S2 (4-10)
    }
}

@Suite("MFCC extraction")
struct MFCCTests {
    @Test func extractFromSilenceProducesFrames() {
        // 1 second of silence at 16kHz
        let samples = [Float](repeating: 0, count: 16000)
        let mfccs = extractMFCC(samples: samples)
        #expect(!mfccs.isEmpty)
        #expect(mfccs[0].count == 13) // default numCoeffs
    }

    @Test func extractFromToneHasNonZeroCoeffs() {
        // 1 second of 440Hz tone
        let samples = (0..<16000).map { i in
            sin(2.0 * Float.pi * 440.0 * Float(i) / 16000.0)
        }
        let mfccs = extractMFCC(samples: samples)
        #expect(!mfccs.isEmpty)
        // MFCC[0] (energy) should be non-zero for a tone
        let hasNonZero = mfccs.contains { frame in frame[0] != 0 }
        #expect(hasNonZero)
    }

    @Test func tooShortAudioReturnsEmpty() {
        let samples = [Float](repeating: 0, count: 100)
        let mfccs = extractMFCC(samples: samples)
        #expect(mfccs.isEmpty)
    }
}

@Suite("Spectral clustering")
struct ClusteringTests {
    @Test func cosineSimilarityOfIdenticalVectors() {
        let a: [Float] = [1, 2, 3]
        #expect(abs(cosineSimilarity(a, a) - 1.0) < 0.001)
    }

    @Test func cosineSimilarityOfOrthogonalVectors() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        #expect(abs(cosineSimilarity(a, b)) < 0.001)
    }

    @Test func clusteringProducesLabels() {
        // Two distinct groups of features should produce at least labels
        var features = [[Float]]()
        // 100 frames of "speaker 1" — high values
        for _ in 0..<100 {
            features.append((0..<13).map { _ in Float.random(in: 5.0...10.0) })
        }
        // 100 frames of "speaker 2" — low values
        for _ in 0..<100 {
            features.append((0..<13).map { _ in Float.random(in: -10.0...(-5.0)) })
        }
        let labels = clusterSpeakers(features: features)
        #expect(!labels.isEmpty)
        // Should detect at least 2 speakers (distinct feature groups)
        let uniqueSpeakers = Set(labels)
        #expect(uniqueSpeakers.count >= 2)
    }

    @Test func labelsToSegmentsMergesConsecutive() {
        let labels = ["Speaker 1", "Speaker 1", "Speaker 2", "Speaker 2", "Speaker 1"]
        let segments = labelsToSegments(labels: labels)
        #expect(segments.count == 3)
        #expect(segments[0].speaker == "Speaker 1")
        #expect(segments[1].speaker == "Speaker 2")
        #expect(segments[2].speaker == "Speaker 1")
    }

    @Test func labelsToSegmentsEmptyInput() {
        let segments = labelsToSegments(labels: [])
        #expect(segments.isEmpty)
    }
}

@Suite("WAV loading")
struct WAVLoadingTests {
    @Test func loadValidWAV() throws {
        // Build a minimal 16kHz mono WAV with 100 samples
        var wav = Data()
        let numSamples: UInt32 = 100
        let dataSize = numSamples * 2
        let fileSize = 36 + dataSize

        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // mono
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Data($0) }) // sample rate
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Data($0) }) // byte rate
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) }) // block align
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }) // bits/sample
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        // Add samples: alternating 1000 and -1000
        for i in 0..<Int(numSamples) {
            let val: Int16 = (i % 2 == 0) ? 1000 : -1000
            wav.append(contentsOf: withUnsafeBytes(of: val.littleEndian) { Data($0) })
        }

        let tmpPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tmpPath) }
        try wav.write(to: tmpPath)

        let samples = try loadWAVAsFloat(tmpPath)
        #expect(samples.count == 100)
        #expect(abs(samples[0] - 1000.0 / 32768.0) < 0.001)
        #expect(abs(samples[1] - (-1000.0 / 32768.0)) < 0.001)
    }

    @Test func loadInvalidFileThrows() {
        let tmpPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        #expect(throws: (any Error).self) {
            _ = try loadWAVAsFloat(tmpPath)
        }
    }
}
