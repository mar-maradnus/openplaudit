/// Opus frame extraction and decoding to PCM.
///
/// Raw file format from PLAUD BLE transfer:
///   Sequence of 89-byte packets:
///     [session_id:4][offset:4][frame_size:1][opus_frame:80]
///   Each opus frame is 20ms of 16kHz mono audio (320 PCM samples).
///
/// Ported from Python CLI `src/plaude/audio/decoder.py`.

import Foundation
import COpus

public let sampleRate: Int32 = 16000
public let channels: Int32 = 1
public let frameDurationMs = 20
public let samplesPerFrame: Int32 = 320  // sampleRate * frameDurationMs / 1000
public let packetSize = 89
public let headerSize = 9  // session_id(4) + offset(4) + frame_size(1)

/// Extract Opus frames from raw PLAUD BLE packets.
///
/// Each packet is 89 bytes: 9-byte header + up to 80-byte Opus frame.
/// The frame_size byte at offset 8 gives the actual Opus frame length.
public func extractOpusFrames(_ rawData: Data) -> [Data] {
    var frames: [Data] = []
    var offset = 0

    while offset + headerSize <= rawData.count {
        if offset + packetSize > rawData.count {
            // Partial trailing packet — extract what we can
            let remaining = rawData.count - offset
            if remaining > headerSize {
                let frameSize = Int(rawData[rawData.startIndex + offset + 8])
                let available = remaining - headerSize
                if frameSize > 0 && available >= frameSize {
                    let start = rawData.startIndex + offset + headerSize
                    frames.append(rawData[start..<start + frameSize])
                }
            }
            break
        }

        let frameSize = Int(rawData[rawData.startIndex + offset + 8])
        if frameSize > 0 && frameSize <= 80 {
            let start = rawData.startIndex + offset + headerSize
            frames.append(rawData[start..<start + frameSize])
        }
        offset += packetSize
    }

    return frames
}

/// Errors from Opus decoding.
public enum OpusDecoderError: Error {
    case createFailed(Int32)
    case decodeFailed(Int32)
}

/// Decode a list of Opus frames to raw PCM (16-bit LE, 16kHz mono).
public func decodeOpusFrames(_ frames: [Data]) throws -> Data {
    var error: Int32 = 0
    guard let decoder = opus_decoder_create(sampleRate, channels, &error) else {
        throw OpusDecoderError.createFailed(error)
    }
    defer { opus_decoder_destroy(decoder) }

    let silenceFrame = Data(count: Int(samplesPerFrame) * 2)
    var pcm = Data()

    for frame in frames {
        var pcmBuffer = [Int16](repeating: 0, count: Int(samplesPerFrame))
        let decoded = frame.withUnsafeBytes { framePtr -> Int32 in
            opus_decode(
                decoder,
                framePtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                Int32(frame.count),
                &pcmBuffer,
                samplesPerFrame,
                0
            )
        }

        if decoded > 0 {
            pcmBuffer.withUnsafeBytes { pcm.append(contentsOf: $0.prefix(Int(decoded) * 2)) }
        } else {
            // Insert silence for corrupted frames
            pcm.append(silenceFrame)
        }
    }

    return pcm
}

/// Decode raw PLAUD BLE data to PCM audio.
public func decodeOpusRaw(_ rawData: Data) throws -> Data {
    let frames = extractOpusFrames(rawData)
    return try decodeOpusFrames(frames)
}
