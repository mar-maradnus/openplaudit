/// NetworkKit tests — frame encoding, HMAC verification, manifest diffing.

import Foundation
import Testing
import CryptoKit
@testable import NetworkKit
import SharedKit

// MARK: - Frame Encoding

@Suite("Frame encoding")
struct FrameEncodingTests {
    @Test func encodeDecodeRoundtrip() throws {
        let msg = SyncMessage.hello(deviceName: "Test", deviceID: "123")
        let frame = try encodeFrame(msg)

        // Frame starts with 4-byte length prefix
        #expect(frame.count > 4)

        // Extract length
        let length = frameLength(from: frame)!
        #expect(Int(length) == frame.count - 4)

        // Decode the JSON payload
        let payload = frame.dropFirst(4)
        let decoded = try decodeMessage(from: Data(payload))
        if case .hello(let name, let id) = decoded {
            #expect(name == "Test")
            #expect(id == "123")
        } else {
            Issue.record("Expected .hello case")
        }
    }

    @Test func frameLengthFromShortData() {
        let short = Data([0x01, 0x02])
        #expect(frameLength(from: short) == nil)
    }

    @Test func frameLengthLittleEndian() {
        // 256 in little-endian = [0x00, 0x01, 0x00, 0x00]
        let data = Data([0x00, 0x01, 0x00, 0x00])
        #expect(frameLength(from: data) == 256)
    }

    @Test func largeMessageRoundtrip() throws {
        // Upload chunk with 64KB of data
        let chunkData = Data(repeating: 0x42, count: 65536)
        let msg = SyncMessage.uploadChunk(recordingID: "big", offset: 0, data: chunkData)
        let frame = try encodeFrame(msg)

        let length = frameLength(from: frame)!
        let payload = frame.dropFirst(4)
        #expect(payload.count == Int(length))

        let decoded = try decodeMessage(from: Data(payload))
        if case .uploadChunk(_, _, let data) = decoded {
            #expect(data.count == 65536)
        } else {
            Issue.record("Expected .uploadChunk case")
        }
    }
}

// MARK: - HMAC Verification

@Suite("HMAC authentication")
struct HMACTests {
    @Test func computeAndVerify() {
        let key = derivePairingKey(from: "123456")
        let nonce = generateNonce()
        let mac = computeHMAC(data: nonce, key: key)

        #expect(verifyHMAC(mac: mac, data: nonce, key: key))
    }

    @Test func wrongKeyFails() {
        let key1 = derivePairingKey(from: "123456")
        let key2 = derivePairingKey(from: "654321")
        let nonce = generateNonce()
        let mac = computeHMAC(data: nonce, key: key1)

        #expect(!verifyHMAC(mac: mac, data: nonce, key: key2))
    }

    @Test func wrongDataFails() {
        let key = derivePairingKey(from: "123456")
        let nonce1 = Data([1, 2, 3, 4])
        let nonce2 = Data([5, 6, 7, 8])
        let mac = computeHMAC(data: nonce1, key: key)

        #expect(!verifyHMAC(mac: mac, data: nonce2, key: key))
    }

    @Test func pairingCodeDerivation_deterministic() {
        let key1 = derivePairingKey(from: "999999")
        let key2 = derivePairingKey(from: "999999")
        // Same code produces same key
        let data = Data("test".utf8)
        let mac1 = computeHMAC(data: data, key: key1)
        let mac2 = computeHMAC(data: data, key: key2)
        #expect(mac1 == mac2)
    }

    @Test func differentCodes_differentKeys() {
        let key1 = derivePairingKey(from: "111111")
        let key2 = derivePairingKey(from: "222222")
        let data = Data("test".utf8)
        let mac1 = computeHMAC(data: data, key: key1)
        let mac2 = computeHMAC(data: data, key: key2)
        #expect(mac1 != mac2)
    }

    @Test func generatedPairingCodeIsSixDigits() {
        for _ in 0..<100 {
            let code = generatePairingCode()
            #expect(code.count == 6)
            #expect(Int(code) != nil)
            #expect(Int(code)! >= 100_000)
            #expect(Int(code)! <= 999_999)
        }
    }

    @Test func nonceIs32Bytes() {
        let nonce = generateNonce()
        #expect(nonce.count == 32)
    }
}

// MARK: - SHA256

@Suite("SHA256")
struct SHA256Tests {
    @Test func knownHash() {
        let data = Data("hello".utf8)
        let hash = sha256Hex(data)
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func emptyDataHash() {
        let hash = sha256Hex(Data())
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

// MARK: - Manifest Diff

@Suite("Manifest diffing")
struct ManifestDiffTests {
    @Test func identifiesNewRecordings() {
        let existing = Set(["rec-1", "rec-2"])
        let manifest = [
            RecordingMeta(id: "rec-1", filename: "a.wav", durationSeconds: 10, recordedAt: Date(), sizeBytes: 1000, status: .recorded),
            RecordingMeta(id: "rec-2", filename: "b.wav", durationSeconds: 20, recordedAt: Date(), sizeBytes: 2000, status: .recorded),
            RecordingMeta(id: "rec-3", filename: "c.wav", durationSeconds: 30, recordedAt: Date(), sizeBytes: 3000, status: .recorded),
        ]
        let needed = manifest.filter { !existing.contains($0.id) }
        #expect(needed.count == 1)
        #expect(needed[0].id == "rec-3")
    }

    @Test func allNewWhenEmpty() {
        let existing = Set<String>()
        let manifest = [
            RecordingMeta(id: "rec-1", filename: "a.wav", durationSeconds: 10, recordedAt: Date(), sizeBytes: 1000, status: .recorded),
        ]
        let needed = manifest.filter { !existing.contains($0.id) }
        #expect(needed.count == 1)
    }

    @Test func noneNeededWhenAllExist() {
        let existing = Set(["rec-1"])
        let manifest = [
            RecordingMeta(id: "rec-1", filename: "a.wav", durationSeconds: 10, recordedAt: Date(), sizeBytes: 1000, status: .recorded),
        ]
        let needed = manifest.filter { !existing.contains($0.id) }
        #expect(needed.isEmpty)
    }
}

// MARK: - Constants

@Suite("Constants")
struct ConstantTests {
    @Test func serviceType() {
        #expect(syncServiceType == "_openplaudit._tcp")
    }

    @Test func chunkSize() {
        #expect(uploadChunkSize == 64 * 1024)
    }
}
