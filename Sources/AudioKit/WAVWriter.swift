/// WAV file writer for raw PCM data.
///
/// Produces standard RIFF WAV: 16-bit LE, mono, 16kHz by default.

import Foundation

/// Default sample rate matching PLAUD's 16kHz Opus encoding.
public let defaultWAVSampleRate: Int32 = 16000

/// Write raw PCM data to a WAV file.
public func saveWAV(_ pcmData: Data, to path: URL, sampleRate: Int32 = defaultWAVSampleRate) throws {
    let wav = buildWAV(pcmData, sampleRate: sampleRate)
    try wav.write(to: path, options: .atomic)
}

/// Convert raw PCM data to in-memory WAV bytes.
public func buildWAV(_ pcmData: Data, sampleRate: Int32 = defaultWAVSampleRate) -> Data {
    let channels: Int16 = 1
    let bitsPerSample: Int16 = 16
    let byteRate = Int32(channels) * sampleRate * Int32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    let dataSize = UInt32(pcmData.count)
    let fileSize = 36 + dataSize  // total - 8 bytes for RIFF header

    var wav = Data()

    // RIFF header
    wav.append(contentsOf: "RIFF".utf8)
    wav.appendLittleEndian(fileSize)
    wav.append(contentsOf: "WAVE".utf8)

    // fmt  chunk
    wav.append(contentsOf: "fmt ".utf8)
    wav.appendLittleEndian(UInt32(16))         // chunk size
    wav.appendLittleEndian(UInt16(1))          // PCM format
    wav.appendLittleEndian(UInt16(channels))
    wav.appendLittleEndian(UInt32(sampleRate))
    wav.appendLittleEndian(UInt32(byteRate))
    wav.appendLittleEndian(UInt16(blockAlign))
    wav.appendLittleEndian(UInt16(bitsPerSample))

    // data chunk
    wav.append(contentsOf: "data".utf8)
    wav.appendLittleEndian(dataSize)
    wav.append(pcmData)

    return wav
}

// MARK: - Data Helpers

extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }

    mutating func appendLittleEndian(_ value: Int32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }
}
