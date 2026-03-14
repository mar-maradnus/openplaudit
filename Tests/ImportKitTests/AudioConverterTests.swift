import Testing
import Foundation
import AVFoundation
@testable import ImportKit

@Suite("Audio conversion")
struct AudioConverterTests {
    @Test func supportedExtensionsIncludeCommonFormats() {
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.wav")))
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.mp3")))
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.m4a")))
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.flac")))
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.mp4")))
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.mov")))
    }

    @Test func unsupportedExtensionsRejected() {
        #expect(!isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.txt")))
        #expect(!isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.pdf")))
        #expect(!isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.zip")))
    }

    @Test func extensionCheckIsCaseInsensitive() {
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.WAV")))
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.Mp3")))
        #expect(isSupportedAudioFile(URL(fileURLWithPath: "/tmp/test.M4A")))
    }

    @Test func convertMissingFileThrows() {
        #expect(throws: AudioConverterError.self) {
            _ = try convertToMonoPCM(fileURL: URL(fileURLWithPath: "/tmp/nonexistent_audio_file.wav"))
        }
    }

    @Test func float32ToInt16ConvertsCorrectly() {
        let samples: [Float] = [0.0, 1.0, -1.0, 0.5]
        let data = samples.withUnsafeBufferPointer { buf in
            float32ToInt16(buf.baseAddress!, count: buf.count)
        }
        #expect(data.count == 8)

        data.withUnsafeBytes { raw in
            let int16s = raw.bindMemory(to: Int16.self)
            #expect(int16s[0] == 0)
            #expect(int16s[1] == 32767)
            #expect(int16s[2] == -32767)
            #expect(int16s[3] == 16383 || int16s[3] == 16384)
        }
    }

    @Test func float32ToInt16ClampsOverflow() {
        let samples: [Float] = [2.0, -2.0]
        let data = samples.withUnsafeBufferPointer { buf in
            float32ToInt16(buf.baseAddress!, count: buf.count)
        }
        data.withUnsafeBytes { raw in
            let int16s = raw.bindMemory(to: Int16.self)
            #expect(int16s[0] == 32767)
            #expect(int16s[1] == -32767)
        }
    }

    @Test func convertSyntheticWAVProducesCorrectOutput() throws {
        // Create a synthetic 44.1kHz mono Int16 WAV, convert to 16kHz, verify
        let sampleRate: Double = 44100
        let duration: Double = 0.5  // 500ms
        let frameCount = Int(sampleRate * duration)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let wavPath = tmpDir.appendingPathComponent("test_44100.wav")

        // Write WAV and close before reading (scope the AVAudioFile)
        do {
            let outputFile = try AVAudioFile(forWriting: wavPath, settings: settings)
            let procFormat = outputFile.processingFormat
            let buffer = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: AVAudioFrameCount(frameCount))!
            buffer.frameLength = AVAudioFrameCount(frameCount)

            let channel = buffer.floatChannelData![0]
            for i in 0..<frameCount {
                channel[i] = sin(2.0 * Float.pi * 440.0 * Float(i) / Float(sampleRate)) * 0.5
            }
            try outputFile.write(from: buffer)
        } // AVAudioFile closed here

        // Convert to 16kHz mono
        let (pcmData, resultDuration) = try convertToMonoPCM(fileURL: wavPath)

        // Duration should be approximately 0.5s
        #expect(abs(resultDuration - 0.5) < 0.05)

        // PCM data should be non-empty 16-bit samples
        #expect(pcmData.count > 0)
        #expect(pcmData.count % 2 == 0)

        // Expected sample count at 16kHz for 0.5s
        let expectedSamples = Int(16000 * 0.5)
        let actualSamples = pcmData.count / 2
        #expect(abs(actualSamples - expectedSamples) < 100)
    }
}
