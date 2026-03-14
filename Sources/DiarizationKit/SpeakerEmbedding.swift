/// Speaker embedding — d-vector representation for persistent speaker identification.
///
/// Extracts a fixed-length embedding from MFCC features for a speaker segment.
/// Used by SpeakerStore for matching speakers across recordings.

import Accelerate
import Foundation

/// A named speaker embedding (d-vector).
public struct SpeakerEmbedding: Codable, Equatable, Sendable {
    public let name: String
    public let embedding: [Float]
    public let createdAt: String
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case name, embedding
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(name: String, embedding: [Float]) {
        self.name = name
        self.embedding = embedding
        let now = ISO8601DateFormatter().string(from: Date())
        self.createdAt = now
        self.updatedAt = now
    }
}

/// Extract a d-vector embedding from audio samples for a given time range.
///
/// Averages MFCC features over the specified segment to produce a
/// fixed-length speaker representation.
func extractSpeakerEmbedding(
    samples: [Float],
    startSample: Int,
    endSample: Int,
    config: MFCCConfig = MFCCConfig()
) -> [Float] {
    let segmentSamples = Array(samples[startSample..<endSample])
    guard segmentSamples.count > config.frameLength else {
        return [Float](repeating: 0, count: config.numCoeffs)
    }

    let mfccs = extractMFCC(samples: segmentSamples, config: config)
    guard !mfccs.isEmpty else {
        return [Float](repeating: 0, count: config.numCoeffs)
    }

    // Average all frames to get a single embedding vector
    let dim = mfccs[0].count
    var embedding = [Float](repeating: 0, count: dim)
    for frame in mfccs {
        for d in 0..<dim {
            embedding[d] += frame[d]
        }
    }
    let scale = 1.0 / Float(mfccs.count)
    for d in 0..<dim {
        embedding[d] *= scale
    }

    // L2-normalize the embedding
    var norm: Float = 0
    vDSP_dotpr(embedding, 1, embedding, 1, &norm, vDSP_Length(dim))
    norm = sqrt(norm)
    if norm > 0 {
        var invNorm = 1.0 / norm
        vDSP_vsmul(embedding, 1, &invNorm, &embedding, 1, vDSP_Length(dim))
    }

    return embedding
}

/// Extract embeddings for all diarized speakers from a WAV file.
///
/// Returns one embedding per unique speaker, computed by averaging
/// embeddings from all segments belonging to that speaker.
public func extractAllSpeakerEmbeddings(
    wavPath: URL,
    diarization: DiarizationResult
) throws -> [String: [Float]] {
    let samples = try loadWAVAsFloat(wavPath)
    let sampleRate = 16000.0

    var speakerFrames: [String: [[Float]]] = [:]

    for segment in diarization.segments {
        let startSample = Int(segment.start * sampleRate)
        let endSample = min(Int(segment.end * sampleRate), samples.count)
        guard endSample > startSample + 400 else { continue }  // Skip very short segments

        let embedding = extractSpeakerEmbedding(
            samples: samples,
            startSample: startSample,
            endSample: endSample
        )

        speakerFrames[segment.speaker, default: []].append(embedding)
    }

    // Average embeddings per speaker
    var result: [String: [Float]] = [:]
    for (speaker, embeddings) in speakerFrames {
        guard !embeddings.isEmpty else { continue }
        let dim = embeddings[0].count
        var avg = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            for d in 0..<dim { avg[d] += emb[d] }
        }
        let scale = 1.0 / Float(embeddings.count)
        for d in 0..<dim { avg[d] *= scale }

        // Re-normalize
        var norm: Float = 0
        vDSP_dotpr(avg, 1, avg, 1, &norm, vDSP_Length(dim))
        norm = sqrt(norm)
        if norm > 0 {
            var invNorm = 1.0 / norm
            vDSP_vsmul(avg, 1, &invNorm, &avg, 1, vDSP_Length(dim))
        }

        result[speaker] = avg
    }

    return result
}
