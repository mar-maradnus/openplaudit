/// ScreenCaptureKit wrapper for meeting audio capture.
///
/// Captures system audio (from a target meeting app) + microphone audio
/// via SCStream. Video frames are discarded in the callback. Audio is
/// delivered as Float32 PCM at 16kHz mono, converted to Int16, and flushed
/// to disk periodically to limit RAM usage during long meetings.

import Foundation
import ScreenCaptureKit
import AVFoundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "audio-capture")

/// Errors from audio capture.
public enum CaptureError: Error, LocalizedError {
    case noMatchingApp(String)
    case streamFailed(String)
    case noAudioData

    public var errorDescription: String? {
        switch self {
        case .noMatchingApp(let id): return "No running app with bundle ID: \(id)"
        case .streamFailed(let msg): return "Capture stream failed: \(msg)"
        case .noAudioData: return "No audio data was captured"
        }
    }
}

/// Captures system + mic audio for a single recording session.
/// Not reusable — create a new instance for each recording.
public final class AudioCaptureSession: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private let outputDir: URL
    private let flushIntervalSeconds: TimeInterval = 60
    private var chunkPaths: [URL] = []
    private var currentChunk = Data()
    private var sampleCount: Int = 0
    private let lock = NSLock()
    private var flushTimer: Timer?

    /// Total samples captured so far (for duration calculation).
    public var totalSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return sampleCount
    }

    public var durationSeconds: Double {
        Double(totalSamples) / 16000.0
    }

    public init(outputDir: URL) {
        self.outputDir = outputDir
        super.init()
    }

    /// Start capturing audio from the specified app's audio output + microphone.
    /// Throws if the app is not found or the stream cannot start.
    ///
    /// Uses app-level SCContentFilter to capture only the meeting app's audio.
    /// `captureMicrophone` mixes mic audio into the same stream (macOS 14+).
    public func start(appBundleID: String, micDeviceID: String = "") async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard content.applications.contains(where: { $0.bundleIdentifier == appBundleID }) else {
            throw CaptureError.noMatchingApp(appBundleID)
        }

        // Display filter including only the target app — captures its audio output.
        // We exclude all other apps so only meeting audio is captured.
        guard let display = content.displays.first else {
            throw CaptureError.streamFailed("No display found")
        }
        let otherApps = content.applications.filter { $0.bundleIdentifier != appBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: otherApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true

        // captureMicrophone mixes mic into the stream (macOS 15+)
        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }

        // Minimise video overhead (we discard all frames)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

        try await stream.startCapture()
        self.stream = stream

        // Start periodic flush timer on main thread
        await MainActor.run {
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: self.flushIntervalSeconds, repeats: true) { [weak self] _ in
                self?.flushToDisk()
            }
        }

        log.info("Audio capture started for \(appBundleID, privacy: .public)")
    }

    /// Stop capturing and return the path to the assembled WAV file.
    public func stop() async throws -> URL {
        // Stop the stream
        if let stream {
            try await stream.stopCapture()
            self.stream = nil
        }

        // Cancel flush timer
        await MainActor.run {
            self.flushTimer?.invalidate()
            self.flushTimer = nil
        }

        // Flush any remaining data
        flushToDisk()

        // Assemble all chunks into a single WAV
        guard !chunkPaths.isEmpty || !currentChunk.isEmpty else {
            throw CaptureError.noAudioData
        }

        return try assembleWAV()
    }

    /// Cancel capture without assembling output.
    public func cancel() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        await MainActor.run {
            self.flushTimer?.invalidate()
            self.flushTimer = nil
        }
        // Clean up chunk files
        for path in chunkPaths {
            try? FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - Internal

    /// Flush current PCM buffer to a numbered chunk file.
    private func flushToDisk() {
        lock.lock()
        guard !currentChunk.isEmpty else {
            lock.unlock()
            return
        }
        let data = currentChunk
        currentChunk = Data()
        lock.unlock()

        let chunkIndex = chunkPaths.count
        let chunkPath = outputDir.appendingPathComponent("chunk_\(chunkIndex).pcm")
        do {
            try data.write(to: chunkPath, options: .atomic)
            lock.lock()
            chunkPaths.append(chunkPath)
            lock.unlock()
            log.debug("Flushed chunk \(chunkIndex): \(data.count) bytes")
        } catch {
            log.error("Failed to flush chunk \(chunkIndex): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Assemble chunk files into a single WAV file.
    private func assembleWAV() throws -> URL {
        var allPCM = Data()
        for path in chunkPaths {
            allPCM.append(try Data(contentsOf: path))
        }

        lock.lock()
        if !currentChunk.isEmpty {
            allPCM.append(currentChunk)
        }
        lock.unlock()

        // Build WAV header + data (reuse AudioKit's buildWAV if available,
        // but for independence we inline the header here)
        let wavData = buildCaptureWAV(allPCM)

        let timestamp = DateFormatter.utcFilename.string(from: Date())
        let wavPath = outputDir.appendingPathComponent("\(timestamp)_UTC.wav")
        try wavData.write(to: wavPath, options: .atomic)

        // Clean up chunks
        for path in chunkPaths {
            try? FileManager.default.removeItem(at: path)
        }

        log.info("Assembled WAV: \(wavPath.lastPathComponent, privacy: .public) (\(allPCM.count) PCM bytes)")
        return wavPath
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureSession: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }  // discard video frames

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var dataLength: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        guard status == noErr, let pointer = dataPointer else { return }

        // Get format description to determine sample format
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)

        // Convert Float32 samples to Int16 PCM
        var int16Data = Data(capacity: numSamples * 2)

        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float32 input
            let floatPointer = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            for i in 0..<numSamples {
                let sample = floatPointer[i]
                let clamped = max(-1.0, min(1.0, sample))
                var int16 = Int16(clamped * 32767.0)
                withUnsafeBytes(of: &int16) { int16Data.append(contentsOf: $0) }
            }
        } else {
            // Already Int16 — just copy
            int16Data.append(Data(bytes: pointer, count: min(dataLength, numSamples * 2)))
        }

        lock.lock()
        currentChunk.append(int16Data)
        sampleCount += numSamples
        lock.unlock()
    }
}

// MARK: - SCStreamDelegate

extension AudioCaptureSession: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped with error: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - WAV Builder

/// Build a WAV file from raw 16-bit PCM data (16kHz mono).
private func buildCaptureWAV(_ pcmData: Data) -> Data {
    let sampleRate: UInt32 = 16000
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    let dataSize = UInt32(pcmData.count)
    let fileSize = 36 + dataSize

    var wav = Data()
    wav.append(contentsOf: "RIFF".utf8)
    wav.append(littleEndianU32: fileSize)
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8)
    wav.append(littleEndianU32: 16)
    wav.append(littleEndianU16: 1)          // PCM
    wav.append(littleEndianU16: channels)
    wav.append(littleEndianU32: sampleRate)
    wav.append(littleEndianU32: byteRate)
    wav.append(littleEndianU16: blockAlign)
    wav.append(littleEndianU16: bitsPerSample)
    wav.append(contentsOf: "data".utf8)
    wav.append(littleEndianU32: dataSize)
    wav.append(pcmData)
    return wav
}

// MARK: - Data helpers (local to this file to avoid conflicts with AudioKit)

private extension Data {
    mutating func append(littleEndianU16 value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }
    mutating func append(littleEndianU32 value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }
}

// MARK: - Float32 → Int16 conversion (pure function, testable)

/// Convert a Float32 audio sample to Int16 PCM.
/// Clamps to [-1.0, 1.0] before scaling.
public func float32ToInt16(_ sample: Float) -> Int16 {
    let clamped = max(-1.0, min(1.0, sample))
    return Int16(clamped * 32767.0)
}

// MARK: - DateFormatter

extension DateFormatter {
    static let utcFilename: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()
}
