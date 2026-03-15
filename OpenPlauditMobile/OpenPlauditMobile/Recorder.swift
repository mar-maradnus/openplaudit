/// iPhone audio recorder — captures 16kHz mono PCM via AVAudioEngine.
///
/// Ported from MicRecorder in MeetingKit. Differences:
/// - AVAudioSession configuration (iOS-only)
/// - Background audio mode (UIBackgroundModes: audio)
/// - No CoreAudio device selection — uses AVAudioSession.setPreferredInput()

import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.mobile", category: "recorder")

/// Audio quality presets.
enum AudioQuality: String, CaseIterable, Identifiable {
    case voice = "Voice"
    case high = "High"

    var id: String { rawValue }

    var sampleRate: Double {
        switch self {
        case .voice: return 16000
        case .high: return 48000
        }
    }

    var channels: AVAudioChannelCount {
        switch self {
        case .voice: return 1
        case .high: return 2
        }
    }

    var description: String {
        switch self {
        case .voice: return "16kHz mono — optimised for speech"
        case .high: return "48kHz stereo — music and ambient"
        }
    }
}

/// Recording result returned when recording stops.
struct Recording: Sendable {
    let wavPath: URL
    let durationSeconds: Double
    let sizeBytes: Int
    let startedAt: Date
}

/// Thread-safe audio buffer that accumulates PCM data from the real-time audio thread.
/// Not MainActor-isolated — safe to use from any thread including the real-time audio thread.
final class AudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var currentChunk = Data()
    private(set) var sampleCount: Int = 0
    private(set) var currentLevel: Float = 0

    func append(_ data: Data, samples: Int, level: Float) {
        lock.lock()
        currentChunk.append(data)
        sampleCount += samples
        currentLevel = level
        lock.unlock()
    }

    func drainChunk() -> Data? {
        lock.lock()
        guard !currentChunk.isEmpty else {
            lock.unlock()
            return nil
        }
        let data = currentChunk
        currentChunk = Data()
        lock.unlock()
        return data
    }

    func readSampleCount() -> Int {
        lock.lock()
        let count = sampleCount
        lock.unlock()
        return count
    }

    func readLevel() -> Float {
        lock.lock()
        let level = currentLevel
        lock.unlock()
        return level
    }

    func reset() {
        lock.lock()
        currentChunk = Data()
        sampleCount = 0
        currentLevel = 0
        lock.unlock()
    }
}

/// Observable recorder for the iOS app.
@MainActor
final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var durationSeconds: Double = 0
    @Published var audioLevel: Float = 0

    private var engine: AVAudioEngine?
    private var chunkPaths: [URL] = []
    private let audioBuffer = AudioBuffer()
    private var flushTimer: Timer?
    private var durationTimer: Timer?
    private var startedAt: Date?
    private var quality: AudioQuality = .voice

    private var outputDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings")
    }

    /// Start recording with the specified audio quality.
    func start(quality: AudioQuality = .voice) throws {
        self.quality = quality
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Configure AVAudioSession for recording
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz mono for voice, 48kHz stereo for high
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: quality.sampleRate,
            channels: quality.channels,
            interleaved: true
        )!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)!
        let buffer = self.audioBuffer
        let channelCount = Int(quality.channels)

        // Tap handler is a free function to avoid inheriting @MainActor isolation.
        // Closures defined inside @MainActor methods inherit that isolation in Swift 6,
        // which crashes when the closure runs on the real-time audio thread.
        let tapHandler = makeTapHandler(
            quality: quality,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            converter: converter,
            buffer: buffer,
            channelCount: channelCount
        )
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tapHandler)

        try engine.start()
        self.engine = engine
        startedAt = Date()
        isRecording = true
        durationSeconds = 0

        // Periodic flush to disk
        flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushToDisk() }
        }

        // Duration + level timer — polls AudioBuffer from main thread
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let samples = buffer.readSampleCount()
            let level = buffer.readLevel()
            Task { @MainActor in
                self?.durationSeconds = Double(samples) / quality.sampleRate
                self?.audioLevel = level
            }
        }

        log.info("Recording started (\(quality.rawValue))")
    }

    /// Stop recording and return the assembled WAV file.
    func stop() throws -> Recording {
        guard let engine else { throw RecorderError.notRecording }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        flushTimer?.invalidate()
        flushTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil

        flushToDisk()

        let totalSamples = audioBuffer.readSampleCount()
        let wavPath = try assembleWAV()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: wavPath.path)[.size] as? Int) ?? 0
        let started = startedAt ?? Date()

        isRecording = false
        durationSeconds = 0
        audioLevel = 0

        log.info("Recording stopped: \(Double(totalSamples) / self.quality.sampleRate)s")

        return Recording(
            wavPath: wavPath,
            durationSeconds: Double(totalSamples) / quality.sampleRate,
            sizeBytes: fileSize,
            startedAt: started
        )
    }

    /// Cancel recording without saving.
    func cancel() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        flushTimer?.invalidate()
        flushTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil

        for path in chunkPaths {
            try? FileManager.default.removeItem(at: path)
        }
        chunkPaths = []
        audioBuffer.reset()
        isRecording = false
        durationSeconds = 0
        audioLevel = 0
    }

    // MARK: - Internal

    private func flushToDisk() {
        guard let data = audioBuffer.drainChunk() else { return }

        let chunkIndex = chunkPaths.count
        let chunkPath = outputDir.appendingPathComponent("chunk_\(chunkIndex).pcm")
        do {
            try data.write(to: chunkPath, options: .atomic)
            chunkPaths.append(chunkPath)
        } catch {
            log.error("Failed to flush chunk \(chunkIndex): \(error.localizedDescription)")
        }
    }

    private func assembleWAV() throws -> URL {
        var allPCM = Data()
        for path in chunkPaths {
            allPCM.append(try Data(contentsOf: path))
        }
        if let remaining = audioBuffer.drainChunk() {
            allPCM.append(remaining)
        }

        let wavData = buildWAV(allPCM)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timestamp = formatter.string(from: startedAt ?? Date())
        let wavPath = outputDir.appendingPathComponent("\(timestamp)_companion_UTC.wav")
        try wavData.write(to: wavPath, options: .atomic)

        // Clean up chunks
        for path in chunkPaths {
            try? FileManager.default.removeItem(at: path)
        }
        chunkPaths = []

        return wavPath
    }

    private func buildWAV(_ pcmData: Data) -> Data {
        let sampleRate = UInt32(quality.sampleRate)
        let channels = UInt16(quality.channels)
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var wav = Data()
        wav.reserveCapacity(44 + pcmData.count)
        wav.append(contentsOf: "RIFF".utf8)
        appendLE32(&wav, fileSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        appendLE32(&wav, 16)
        appendLE16(&wav, 1)            // PCM
        appendLE16(&wav, channels)
        appendLE32(&wav, sampleRate)
        appendLE32(&wav, byteRate)
        appendLE16(&wav, blockAlign)
        appendLE16(&wav, bitsPerSample)
        wav.append(contentsOf: "data".utf8)
        appendLE32(&wav, dataSize)
        wav.append(pcmData)
        return wav
    }
}

// MARK: - Tap Handler (must be a free function — not @MainActor-isolated)

/// Creates the AVAudioEngine tap handler closure.
/// This is a free function (not a method on @MainActor Recorder) so the returned closure
/// inherits no actor isolation and can safely run on the real-time audio thread.
private func makeTapHandler(
    quality: AudioQuality,
    inputFormat: AVAudioFormat,
    targetFormat: AVAudioFormat,
    converter: AVAudioConverter,
    buffer: AudioBuffer,
    channelCount: Int
) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    return { inBuffer, _ in
        let ratio = quality.sampleRate / inputFormat.sampleRate
        let frameCount = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio)
        guard frameCount > 0 else { return }

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, error == nil else { return }

        let count = Int(convertedBuffer.frameLength)
        guard let floatData = convertedBuffer.floatChannelData else { return }

        // Compute audio level for waveform display (stored in buffer, read by timer)
        var level: Float = 0
        let ch0 = floatData[0]
        for i in 0..<count { level += abs(ch0[i]) }
        level /= Float(max(count, 1))

        // Convert Float32 to Int16 PCM
        var int16Data = Data(capacity: count * channelCount * 2)
        for i in 0..<count {
            for ch in 0..<channelCount {
                let sample = max(-1.0, min(1.0, floatData[ch][i]))
                var int16 = Int16(sample * 32767.0)
                withUnsafeBytes(of: &int16) { int16Data.append(contentsOf: $0) }
            }
        }

        buffer.append(int16Data, samples: count, level: level)
    }
}

// MARK: - WAV Helpers

private func appendLE16(_ data: inout Data, _ value: UInt16) {
    var le = value.littleEndian
    data.append(Data(bytes: &le, count: 2))
}

private func appendLE32(_ data: inout Data, _ value: UInt32) {
    var le = value.littleEndian
    data.append(Data(bytes: &le, count: 4))
}

// MARK: - Errors

enum RecorderError: Error, LocalizedError {
    case notRecording

    var errorDescription: String? {
        switch self {
        case .notRecording: return "No recording in progress"
        }
    }
}
