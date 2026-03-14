/// Audio format conversion — any supported format to 16kHz mono 16-bit WAV.
///
/// Uses ExtAudioFile (Audio Toolbox) for resampling and channel mixing.
/// Supports all formats Core Audio handles: WAV, MP3, M4A, FLAC, CAF, AIFF, MP4, MOV, etc.

import AudioToolbox
import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "import")

public enum AudioConverterError: Error, LocalizedError {
    case cannotReadFile(String)
    case conversionFailed(String)
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .cannotReadFile(let path): return "Cannot read audio file: \(path)"
        case .conversionFailed(let reason): return "Audio conversion failed: \(reason)"
        case .emptyAudio: return "Audio file contains no samples"
        }
    }
}

/// Convert any audio/video file to 16kHz mono 16-bit PCM WAV data.
///
/// Uses ExtAudioFile which handles resampling and channel mixing natively.
/// Reads in 10-second chunks to limit memory usage for long recordings.
///
/// Returns raw Int16 PCM data (no WAV header) and duration in seconds.
/// Caller wraps with `buildWAV()` from AudioKit.
public func convertToMonoPCM(fileURL: URL) throws -> (pcmData: Data, durationSeconds: Double) {
    var extFile: ExtAudioFileRef?
    var status = ExtAudioFileOpenURL(fileURL as CFURL, &extFile)
    guard status == noErr, let extFile else {
        throw AudioConverterError.cannotReadFile(fileURL.path)
    }
    defer { ExtAudioFileDispose(extFile) }

    // Get source format for logging
    var sourceDesc = AudioStreamBasicDescription()
    var descSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    status = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &descSize, &sourceDesc)
    guard status == noErr else {
        throw AudioConverterError.cannotReadFile(fileURL.path)
    }

    // Get total frame count
    var fileLengthFrames: Int64 = 0
    var lengthSize = UInt32(MemoryLayout<Int64>.size)
    status = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &fileLengthFrames)
    guard status == noErr, fileLengthFrames > 0 else {
        throw AudioConverterError.emptyAudio
    }

    // Set client format: 16kHz mono Float32 interleaved
    let targetSampleRate: Float64 = 16000
    var clientDesc = AudioStreamBasicDescription(
        mSampleRate: targetSampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientDesc)
    guard status == noErr else {
        throw AudioConverterError.conversionFailed("Cannot set client format (status: \(status))")
    }

    // Read in chunks — 10 seconds at 16kHz per iteration
    let chunkFrames: UInt32 = 160000
    let bufferByteSize = Int(chunkFrames) * 4  // Float32 = 4 bytes per sample
    let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferByteSize, alignment: 4)
    defer { rawBuffer.deallocate() }

    var allPCM = Data()
    while true {
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bufferByteSize),
                mData: rawBuffer
            )
        )
        var frameCount = chunkFrames
        status = ExtAudioFileRead(extFile, &frameCount, &bufferList)
        guard status == noErr else {
            throw AudioConverterError.conversionFailed("Read failed (status: \(status))")
        }
        if frameCount == 0 { break }

        // Convert Float32 → Int16
        let floatPtr = rawBuffer.bindMemory(to: Float.self, capacity: Int(frameCount))
        var int16Data = Data(count: Int(frameCount) * 2)
        int16Data.withUnsafeMutableBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                let sample = max(-1.0, min(1.0, floatPtr[i]))
                int16Ptr[i] = Int16(sample * 32767.0)
            }
        }
        allPCM.append(int16Data)
    }

    guard !allPCM.isEmpty else {
        throw AudioConverterError.emptyAudio
    }

    let outputSamples = allPCM.count / 2
    let duration = Double(outputSamples) / targetSampleRate

    log.info("Converted \(fileURL.lastPathComponent, privacy: .public): \(sourceDesc.mSampleRate)Hz \(sourceDesc.mChannelsPerFrame)ch → 16kHz mono, \(String(format: "%.1f", duration))s")

    return (allPCM, duration)
}

/// Convert Float32 PCM buffer to Int16 PCM data (little-endian).
/// Used by AudioCaptureSession for ScreenCaptureKit callback buffers.
public func float32ToInt16(_ floatSamples: UnsafePointer<Float>, count: Int) -> Data {
    var data = Data(count: count * 2)
    data.withUnsafeMutableBytes { raw in
        let int16Ptr = raw.bindMemory(to: Int16.self)
        for i in 0..<count {
            let sample = max(-1.0, min(1.0, floatSamples[i]))
            int16Ptr[i] = Int16(sample * 32767.0)
        }
    }
    return data
}

/// Supported file extensions for import.
public let supportedAudioExtensions: Set<String> = [
    "wav", "mp3", "m4a", "aac", "flac", "caf", "aiff", "aif",
    "mp4", "mov", "m4v", "ogg", "opus", "wma", "webm"
]

/// Check if a file extension is a supported audio/video format.
public func isSupportedAudioFile(_ url: URL) -> Bool {
    supportedAudioExtensions.contains(url.pathExtension.lowercased())
}
