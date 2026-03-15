/// SharedKit tests — Codable round-trip for all extracted types, SyncMessage encode/decode.

import Foundation
import Testing
@testable import SharedKit

// MARK: - TranscriptionResult

@Suite("TranscriptionResult Codable")
struct TranscriptionResultTests {
    @Test func roundtripFullResult() throws {
        let result = TranscriptionResult(
            file: "test_recording",
            durationSeconds: 123.45,
            model: "medium",
            language: "en",
            segments: [
                .init(start: 0, end: 5.2, text: "Hello world", speaker: "Speaker 1"),
                .init(start: 5.2, end: 10.0, text: "How are you"),
            ],
            text: "Hello world How are you",
            speakers: ["Speaker 1", "Speaker 2"],
            summary: .init(template: "key_points", model: "qwen2.5:3b", content: "Summary here"),
            mindmap: "# Root\n## Branch"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)

        #expect(decoded.file == result.file)
        #expect(decoded.durationSeconds == result.durationSeconds)
        #expect(decoded.model == result.model)
        #expect(decoded.language == result.language)
        #expect(decoded.segments.count == 2)
        #expect(decoded.segments[0].text == "Hello world")
        #expect(decoded.segments[0].speaker == "Speaker 1")
        #expect(decoded.segments[1].speaker == nil)
        #expect(decoded.text == result.text)
        #expect(decoded.speakers == result.speakers)
        #expect(decoded.summary?.template == "key_points")
        #expect(decoded.mindmap == result.mindmap)
    }

    @Test func codingKeysUseSnakeCase() throws {
        let result = TranscriptionResult(
            file: "test", durationSeconds: 1.0, model: "tiny",
            language: "en", segments: [], text: ""
        )
        let data = try JSONEncoder().encode(result)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("duration_seconds"))
        #expect(!json.contains("durationSeconds"))
    }

    @Test func minimalResultRoundtrips() throws {
        let result = TranscriptionResult(
            file: "minimal", durationSeconds: 0, model: "tiny",
            language: "en", segments: [], text: ""
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        #expect(decoded.speakers == nil)
        #expect(decoded.summary == nil)
        #expect(decoded.mindmap == nil)
    }
}

// MARK: - DiarizationResult

@Suite("DiarizationResult Codable")
struct DiarizationResultCodableTests {
    @Test func speakerSegmentDuration() {
        let seg = SpeakerSegment(start: 1.0, end: 3.5, speaker: "Speaker 1")
        #expect(seg.duration == 2.5)
    }

    @Test func roundtrip() throws {
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
}

// MARK: - SummaryResult

@Suite("SummaryResult Codable")
struct SummaryResultCodableTests {
    @Test func roundtrip() throws {
        let result = SummaryResult(template: "key_points", model: "qwen2.5:3b", content: "Summary content")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SummaryResult.self, from: data)
        #expect(decoded == result)
    }
}

// MARK: - RecordingMeta

@Suite("RecordingMeta")
struct RecordingMetaTests {
    @Test func roundtrip() throws {
        let meta = RecordingMeta(
            id: "abc-123",
            filename: "20240101_120000_companion_UTC.wav",
            durationSeconds: 45.5,
            recordedAt: Date(timeIntervalSinceReferenceDate: 0),
            sizeBytes: 1_440_000,
            status: .recorded
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(RecordingMeta.self, from: data)
        #expect(decoded == meta)
        #expect(decoded.status == .recorded)
    }

    @Test func allStatusValues() throws {
        let cases: [RecordingStatus] = [.recorded, .syncing, .synced, .transcribing, .transcribed, .failed]
        for status in cases {
            let json = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(RecordingStatus.self, from: json)
            #expect(decoded == status)
        }
    }
}

// MARK: - SyncMessage

@Suite("SyncMessage")
struct SyncMessageTests {
    @Test func helloRoundtrip() throws {
        let msg = SyncMessage.hello(deviceName: "iPhone 15", deviceID: "abc-123")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        if case .hello(let name, let id) = decoded {
            #expect(name == "iPhone 15")
            #expect(id == "abc-123")
        } else {
            Issue.record("Expected .hello case")
        }
    }

    @Test func authChallengeRoundtrip() throws {
        let nonce = Data([0x01, 0x02, 0x03, 0x04])
        let msg = SyncMessage.authChallenge(nonce: nonce)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        if case .authChallenge(let decodedNonce) = decoded {
            #expect(decodedNonce == nonce)
        } else {
            Issue.record("Expected .authChallenge case")
        }
    }

    @Test func transcriptReadyRoundtrip() throws {
        let transcript = TranscriptionResult(
            file: "test", durationSeconds: 10, model: "medium",
            language: "en",
            segments: [.init(start: 0, end: 5, text: "Hello")],
            text: "Hello"
        )
        let msg = SyncMessage.transcriptReady(recordingID: "rec-1", transcript: transcript)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        if case .transcriptReady(let id, let tx) = decoded {
            #expect(id == "rec-1")
            #expect(tx.text == "Hello")
        } else {
            Issue.record("Expected .transcriptReady case")
        }
    }

    @Test func errorRoundtrip() throws {
        let msg = SyncMessage.error("Something went wrong")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        if case .error(let errMsg) = decoded {
            #expect(errMsg == "Something went wrong")
        } else {
            Issue.record("Expected .error case")
        }
    }

    @Test func uploadChunkRoundtrip() throws {
        let chunkData = Data(repeating: 0xAB, count: 1024)
        let msg = SyncMessage.uploadChunk(recordingID: "rec-1", offset: 64000, data: chunkData)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        if case .uploadChunk(let id, let offset, let chunk) = decoded {
            #expect(id == "rec-1")
            #expect(offset == 64000)
            #expect(chunk == chunkData)
        } else {
            Issue.record("Expected .uploadChunk case")
        }
    }

    @Test func uploadCompleteRoundtrip() throws {
        let msg = SyncMessage.uploadComplete(recordingID: "rec-1", sha256: "abc123def456")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        if case .uploadComplete(let id, let hash) = decoded {
            #expect(id == "rec-1")
            #expect(hash == "abc123def456")
        } else {
            Issue.record("Expected .uploadComplete case")
        }
    }

    @Test func recordingManifestRoundtrip() throws {
        let meta = RecordingMeta(
            id: "rec-1", filename: "test.wav", durationSeconds: 30,
            recordedAt: Date(timeIntervalSinceReferenceDate: 0),
            sizeBytes: 960000, status: .recorded
        )
        let msg = SyncMessage.recordingManifest([meta])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        if case .recordingManifest(let manifests) = decoded {
            #expect(manifests.count == 1)
            #expect(manifests[0].id == "rec-1")
        } else {
            Issue.record("Expected .recordingManifest case")
        }
    }
}
