/// Microphone recorder — captures audio from any input device via AVAudioEngine.
///
/// Records 16kHz mono Int16 PCM, flushes to disk periodically, assembles
/// a WAV on stop. No ScreenCaptureKit — just microphone access.

import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "mic-recorder")

/// Records audio from a microphone to a WAV file.
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let outputDir: URL
    private var chunkPaths: [URL] = []
    private var currentChunk = Data()
    private var sampleCount: Int = 0
    private let lock = NSLock()
    private var flushTimer: Timer?
    private let flushInterval: TimeInterval = 60

    public struct Recording: Sendable {
        public let wavPath: URL
        public let durationSeconds: Double
        public let startedAt: Date
    }

    private var startedAt: Date?

    public var durationSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(sampleCount) / 16000.0
    }

    public init(outputDir: URL) {
        self.outputDir = outputDir
    }

    /// Start recording from the specified microphone (empty = system default).
    public func start(micDeviceID: String = "") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Select mic device if specified
        if !micDeviceID.isEmpty {
            var deviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)

            let devices = getAudioDevices()
            if let match = devices.first(where: { $0.uid == micDeviceID }) {
                deviceID = match.id
                var propAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                // Set the engine's input device
                let inputNode = engine.inputNode
                let inputUnit = inputNode.audioUnit!
                AudioUnitSetProperty(
                    inputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Convert to 16kHz mono Float32 for processing
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: true)!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
            guard frameCount > 0 else { return }

            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else { return }

            // Convert Float32 to Int16 PCM
            let count = Int(convertedBuffer.frameLength)
            guard let floatData = convertedBuffer.floatChannelData?[0] else { return }

            var int16Data = Data(capacity: count * 2)
            for i in 0..<count {
                let sample = max(-1.0, min(1.0, floatData[i]))
                var int16 = Int16(sample * 32767.0)
                withUnsafeBytes(of: &int16) { int16Data.append(contentsOf: $0) }
            }

            self.lock.lock()
            self.currentChunk.append(int16Data)
            self.sampleCount += count
            self.lock.unlock()
        }

        try engine.start()
        startedAt = Date()

        // Periodic flush
        DispatchQueue.main.async {
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: self.flushInterval, repeats: true) { [weak self] _ in
                self?.flushToDisk()
            }
        }

        log.info("Microphone recording started")
    }

    /// Stop recording and return the assembled WAV file.
    public func stop() throws -> Recording {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        flushTimer?.invalidate()
        flushTimer = nil

        flushToDisk()

        let wavPath = try assembleWAV()
        let duration = durationSeconds
        let started = startedAt ?? Date()

        log.info("Microphone recording stopped: \(duration, privacy: .public)s")

        return Recording(wavPath: wavPath, durationSeconds: duration, startedAt: started)
    }

    /// Cancel recording without saving.
    public func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        flushTimer?.invalidate()
        flushTimer = nil

        for path in chunkPaths {
            try? FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - Internal

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
        let chunkPath = outputDir.appendingPathComponent("mic_chunk_\(chunkIndex).pcm")
        do {
            try data.write(to: chunkPath, options: .atomic)
            lock.lock()
            chunkPaths.append(chunkPath)
            lock.unlock()
        } catch {
            log.error("Failed to flush mic chunk \(chunkIndex): \(error.localizedDescription, privacy: .public)")
        }
    }

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

        let wavData = buildMicWAV(allPCM)
        let timestamp = DateFormatter.utcFilename.string(from: startedAt ?? Date())
        let wavPath = outputDir.appendingPathComponent("\(timestamp)_mic_UTC.wav")
        try wavData.write(to: wavPath, options: .atomic)

        for path in chunkPaths {
            try? FileManager.default.removeItem(at: path)
        }

        return wavPath
    }
}

// MARK: - WAV Builder

private func buildMicWAV(_ pcmData: Data) -> Data {
    let sampleRate: UInt32 = 16000
    let channels: UInt16 = 1
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
    appendLE16(&wav, 1)        // PCM
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

private func appendLE16(_ data: inout Data, _ value: UInt16) {
    var le = value.littleEndian
    data.append(Data(bytes: &le, count: 2))
}

private func appendLE32(_ data: inout Data, _ value: UInt32) {
    var le = value.littleEndian
    data.append(Data(bytes: &le, count: 4))
}

// MARK: - Audio Device Enumeration

private struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

private func getAudioDevices() -> [AudioDevice] {
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size, &deviceIDs)

    return deviceIDs.compactMap { id -> AudioDevice? in
        // Get UID
        var uidProp = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &uidProp, 0, nil, &uidSize, &uid)

        // Get name
        var nameProp = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &nameProp, 0, nil, &nameSize, &name)

        return AudioDevice(id: id, uid: uid as String, name: name as String)
    }
}
