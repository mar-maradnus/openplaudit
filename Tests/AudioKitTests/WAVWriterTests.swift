/// Tests for WAV writing — header structure, roundtrip verification.

import Foundation
import Testing
@testable import AudioKit

@Suite("WAV Writer")
struct WAVWriterTests {
    @Test func headerStructure() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = buildWAV(pcm)

        // RIFF header
        #expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")

        // fmt chunk
        #expect(String(data: wav[12..<16], encoding: .ascii) == "fmt ")
        let fmtSize: UInt32 = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian }
        #expect(fmtSize == 16)

        // PCM format = 1
        let format: UInt16 = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt16.self).littleEndian }
        #expect(format == 1)

        // Mono
        let channels: UInt16 = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: UInt16.self).littleEndian }
        #expect(channels == 1)

        // 16kHz
        let sampleRate: UInt32 = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian }
        #expect(sampleRate == 16000)

        // 16-bit
        let bitsPerSample: UInt16 = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self).littleEndian }
        #expect(bitsPerSample == 16)

        // data chunk
        #expect(String(data: wav[36..<40], encoding: .ascii) == "data")
        let dataSize: UInt32 = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian }
        #expect(dataSize == UInt32(pcm.count))
    }

    @Test func roundtripFileWriteRead() throws {
        // Create PCM with a known pattern: alternating silence and max
        var pcm = Data()
        for i: Int16 in 0..<100 {
            var le = i.littleEndian
            pcm.append(Data(bytes: &le, count: 2))
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wavPath = dir.appendingPathComponent("test.wav")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try saveWAV(pcm, to: wavPath)

        // Read back and verify
        let readData = try Data(contentsOf: wavPath)
        #expect(readData.count == 44 + pcm.count)

        // Verify PCM data is intact after header
        let readPCM = readData.dropFirst(44)
        #expect(readPCM == pcm)
    }

    @Test func emptyPCMProducesValidHeader() {
        let wav = buildWAV(Data())
        #expect(wav.count == 44)
        #expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF")
    }

    @Test func fileSizeFieldCorrect() {
        let pcm = Data(repeating: 0xAB, count: 256)
        let wav = buildWAV(pcm)
        let fileSize: UInt32 = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
        // RIFF file size = total - 8
        #expect(fileSize == UInt32(wav.count - 8))
    }

    @Test func customSampleRate() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = buildWAV(pcm, sampleRate: 44100)
        let sampleRate: UInt32 = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian }
        #expect(sampleRate == 44100)
    }
}
