/// Speaker embedding and store tests — d-vector extraction, storage, matching.

import Testing
import Foundation
@testable import DiarizationKit

@Suite("SpeakerEmbedding")
struct SpeakerEmbeddingTests {

    @Test func init_setsTimestamps() {
        let emb = SpeakerEmbedding(name: "Alice", embedding: [1, 0, 0])
        #expect(emb.name == "Alice")
        #expect(emb.createdAt == emb.updatedAt)
        #expect(!emb.createdAt.isEmpty)
    }

    @Test func isCodable() throws {
        let emb = SpeakerEmbedding(name: "Bob", embedding: [0.5, -0.3, 0.8])
        let data = try JSONEncoder().encode(emb)
        let decoded = try JSONDecoder().decode(SpeakerEmbedding.self, from: data)
        #expect(decoded.name == "Bob")
        #expect(decoded.embedding == emb.embedding)
    }

    @Test func codingKeys_useSnakeCase() throws {
        let emb = SpeakerEmbedding(name: "Test", embedding: [1.0])
        let data = try JSONEncoder().encode(emb)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("created_at"))
        #expect(json.contains("updated_at"))
        #expect(!json.contains("createdAt"))
    }
}

@Suite("extractSpeakerEmbedding")
struct ExtractSpeakerEmbeddingTests {

    @Test func shortSegment_returnsZeroVector() {
        let config = MFCCConfig()
        // Less than frameLength samples
        let samples = [Float](repeating: 0.1, count: config.frameLength - 1)
        let emb = extractSpeakerEmbedding(
            samples: samples,
            startSample: 0,
            endSample: samples.count,
            config: config
        )
        #expect(emb.count == config.numCoeffs)
        #expect(emb.allSatisfy { $0 == 0 })
    }

    @Test func normalSegment_returnsNormalizedVector() {
        // Generate a simple sine wave segment
        let sampleRate = 16000
        let duration = 0.1  // 100ms
        let numSamples = Int(Double(sampleRate) * duration)
        let samples = (0..<numSamples).map { Float(sin(Double($0) * 440.0 * 2 * .pi / Double(sampleRate))) }

        let emb = extractSpeakerEmbedding(
            samples: samples,
            startSample: 0,
            endSample: samples.count
        )

        #expect(emb.count == 13)  // default numCoeffs

        // Check L2 normalization (should be ~1.0)
        let norm = sqrt(emb.reduce(0) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 0.01 || norm == 0)
    }
}

@Suite("SpeakerStore")
struct SpeakerStoreTests {

    private func makeTempStore() -> SpeakerStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openplaudit-test-speakers-\(UUID().uuidString)")
        return SpeakerStore(directory: dir)
    }

    @Test func emptyStore_loadsEmpty() {
        let store = makeTempStore()
        let all = store.loadAll()
        #expect(all.isEmpty)
        #expect(store.count == 0)
    }

    @Test func saveAndLoad_roundtrips() throws {
        let store = makeTempStore()
        let emb = SpeakerEmbedding(name: "Alice", embedding: [0.5, -0.3, 0.8])
        try store.save(emb)

        let all = store.loadAll()
        #expect(all.count == 1)
        #expect(all[0].name == "Alice")
        #expect(all[0].embedding == emb.embedding)
    }

    @Test func saveOverwrites_existingSpeaker() throws {
        let store = makeTempStore()
        try store.save(SpeakerEmbedding(name: "Alice", embedding: [1, 0, 0]))
        try store.save(SpeakerEmbedding(name: "Alice", embedding: [0, 1, 0]))

        let all = store.loadAll()
        #expect(all.count == 1)
        #expect(all[0].embedding == [0, 1, 0])
    }

    @Test func delete_removesSpeaker() throws {
        let store = makeTempStore()
        try store.save(SpeakerEmbedding(name: "Alice", embedding: [1, 0, 0]))
        try store.delete(name: "Alice")
        #expect(store.count == 0)
    }

    @Test func rename_changesSpeakerName() throws {
        let store = makeTempStore()
        try store.save(SpeakerEmbedding(name: "Unknown", embedding: [0.5, 0.5]))
        try store.rename(from: "Unknown", to: "Bob")

        let all = store.loadAll()
        #expect(all.count == 1)
        #expect(all[0].name == "Bob")
        #expect(all[0].embedding == [0.5, 0.5])
    }

    @Test func rename_nonExistent_throws() throws {
        let store = makeTempStore()
        #expect(throws: SpeakerStoreError.self) {
            try store.rename(from: "Ghost", to: "Real")
        }
    }
}

@Suite("matchSpeakers")
struct MatchSpeakersTests {

    @Test func identicalEmbedding_matches() {
        let stored = [SpeakerEmbedding(name: "Alice", embedding: [1, 0, 0])]
        let diarized: [String: [Float]] = ["Speaker 1": [1, 0, 0]]

        let mapping = matchSpeakers(diarizedEmbeddings: diarized, storedSpeakers: stored, threshold: 0.5)
        #expect(mapping["Speaker 1"] == "Alice")
    }

    @Test func orthogonalEmbedding_doesNotMatch() {
        let stored = [SpeakerEmbedding(name: "Alice", embedding: [1, 0, 0])]
        let diarized: [String: [Float]] = ["Speaker 1": [0, 1, 0]]

        let mapping = matchSpeakers(diarizedEmbeddings: diarized, storedSpeakers: stored, threshold: 0.5)
        #expect(mapping.isEmpty)
    }

    @Test func multipleStoredSpeakers_matchesBest() {
        let stored = [
            SpeakerEmbedding(name: "Alice", embedding: [1, 0, 0]),
            SpeakerEmbedding(name: "Bob", embedding: [0, 1, 0]),
        ]
        let diarized: [String: [Float]] = [
            "Speaker 1": [0.95, 0.05, 0],
            "Speaker 2": [0.05, 0.95, 0],
        ]

        let mapping = matchSpeakers(diarizedEmbeddings: diarized, storedSpeakers: stored, threshold: 0.5)
        #expect(mapping["Speaker 1"] == "Alice")
        #expect(mapping["Speaker 2"] == "Bob")
    }

    @Test func belowThreshold_noMatch() {
        let stored = [SpeakerEmbedding(name: "Alice", embedding: [1, 0, 0])]
        let diarized: [String: [Float]] = ["Speaker 1": [0.6, 0.8, 0]]

        // With high threshold, the 0.6 cosine similarity shouldn't match
        let mapping = matchSpeakers(diarizedEmbeddings: diarized, storedSpeakers: stored, threshold: 0.9)
        #expect(mapping.isEmpty)
    }
}

@Suite("applySpeakerNames")
struct ApplySpeakerNamesTests {

    @Test func replacesMatchedLabels() {
        let diarization = DiarizationResult(
            segments: [
                SpeakerSegment(start: 0, end: 5, speaker: "Speaker 1"),
                SpeakerSegment(start: 5, end: 10, speaker: "Speaker 2"),
            ],
            speakers: ["Speaker 1", "Speaker 2"],
            method: "test"
        )
        let mapping = ["Speaker 1": "Alice", "Speaker 2": "Bob"]

        let result = applySpeakerNames(to: diarization, mapping: mapping)
        #expect(result.segments[0].speaker == "Alice")
        #expect(result.segments[1].speaker == "Bob")
        #expect(result.speakers == ["Alice", "Bob"])
    }

    @Test func unmatchedLabels_keptAsIs() {
        let diarization = DiarizationResult(
            segments: [
                SpeakerSegment(start: 0, end: 5, speaker: "Speaker 1"),
                SpeakerSegment(start: 5, end: 10, speaker: "Speaker 2"),
            ],
            speakers: ["Speaker 1", "Speaker 2"],
            method: "test"
        )
        let mapping = ["Speaker 1": "Alice"]

        let result = applySpeakerNames(to: diarization, mapping: mapping)
        #expect(result.segments[0].speaker == "Alice")
        #expect(result.segments[1].speaker == "Speaker 2")
    }
}
