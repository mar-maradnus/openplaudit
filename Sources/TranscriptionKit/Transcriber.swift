/// Whisper.cpp wrapper via SwiftWhisper — model loading, transcription, result formatting.

import Foundation
import SwiftWhisper
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "transcription")

/// Transcription result matching CLI JSON format.
/// Speaker field is optional — nil when diarization is disabled.
public struct TranscriptionResult: Codable, Sendable {
    public let file: String
    public let durationSeconds: Double
    public let model: String
    public let language: String
    public let segments: [Segment]
    public let text: String
    public var speakers: [String]?
    public var summary: TranscriptSummary?
    public var mindmap: String?

    /// Summary attached to a transcript by the summarisation pipeline.
    public struct TranscriptSummary: Codable, Sendable {
        public let template: String
        public let model: String
        public let content: String

        public init(template: String, model: String, content: String) {
            self.template = template
            self.model = model
            self.content = content
        }
    }

    public struct Segment: Codable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
        public var speaker: String?
    }

    public init(file: String, durationSeconds: Double, model: String, language: String, segments: [Segment], text: String, speakers: [String]? = nil, summary: TranscriptSummary? = nil, mindmap: String? = nil) {
        self.file = file
        self.durationSeconds = durationSeconds
        self.model = model
        self.language = language
        self.segments = segments
        self.text = text
        self.speakers = speakers
        self.summary = summary
        self.mindmap = mindmap
    }

    enum CodingKeys: String, CodingKey {
        case file
        case durationSeconds = "duration_seconds"
        case model, language, segments, text, speakers, summary, mindmap
    }
}

/// Model download directory.
public let modelsDir: URL = {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/openplaudit/models")
}()

/// Model file URLs by name.
public let modelURLs: [String: String] = [
    "tiny":    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
    "tiny.en": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
    "base":    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
    "base.en": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
    "small":   "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
    "small.en":"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
    "medium":  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
    "medium.en":"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin",
    "large":   "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
]

/// Transcriber using SwiftWhisper (whisper.cpp).
public final class Transcriber: @unchecked Sendable {
    private let modelName: String
    private var whisper: Whisper?

    public init(model: String = "medium") {
        self.modelName = model
    }

    /// Ensure the model file is downloaded. Returns the local path.
    public func ensureModel() async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let filename = "ggml-\(modelName).bin"
        let localPath = modelsDir.appendingPathComponent(filename)

        if fm.fileExists(atPath: localPath.path) { return localPath }

        guard let urlString = modelURLs[modelName],
              let url = URL(string: urlString) else {
            throw TranscriptionError.unknownModel(modelName)
        }

        log.info("Downloading whisper model '\(self.modelName, privacy: .public)' (\(filename, privacy: .public))...")
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        try fm.moveItem(at: tempURL, to: localPath)
        log.info("Model downloaded to \(localPath.path, privacy: .public)")

        return localPath
    }

    /// Load the model into memory (if not already loaded).
    public func loadModel() async throws {
        if whisper != nil { return }
        let modelPath = try await ensureModel()
        whisper = Whisper(fromFileURL: modelPath)
    }

    /// Transcribe a WAV file. Returns the result in CLI-compatible format.
    public func transcribe(wavPath: URL, language: String = "en") async throws -> TranscriptionResult {
        try await loadModel()
        guard let whisper else { throw TranscriptionError.modelNotLoaded }

        // Load WAV as 16kHz float PCM
        let audioFrames = try loadWAVAs16kHzFloat(wavPath)
        let duration = Double(audioFrames.count) / 16000.0

        // Transcribe
        let segments = try await whisper.transcribe(audioFrames: audioFrames)

        let resultSegments = segments.map { seg in
            TranscriptionResult.Segment(
                start: Double(seg.startTime) / 1000.0,
                end: Double(seg.endTime) / 1000.0,
                text: seg.text.trimmingCharacters(in: .whitespaces)
            )
        }

        let fullText = resultSegments.map(\.text).joined(separator: " ")

        return TranscriptionResult(
            file: wavPath.deletingPathExtension().lastPathComponent,
            durationSeconds: duration,
            model: modelName,
            language: language,
            segments: resultSegments,
            text: fullText
        )
    }
}

// MARK: - Errors

public enum TranscriptionError: Error, LocalizedError {
    case unknownModel(String)
    case modelNotLoaded
    case invalidWAV(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let m): return "Unknown model: \(m)"
        case .modelNotLoaded: return "Whisper model not loaded"
        case .invalidWAV(let msg): return "Invalid WAV: \(msg)"
        }
    }
}

// MARK: - WAV Loading

/// Load a 16kHz mono 16-bit PCM WAV file as [Float] samples normalized to [-1, 1].
private func loadWAVAs16kHzFloat(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 44 else {
        throw TranscriptionError.invalidWAV("File too small for WAV header")
    }

    // Verify RIFF header
    let riff = String(data: data[0..<4], encoding: .ascii)
    let wave = String(data: data[8..<12], encoding: .ascii)
    guard riff == "RIFF", wave == "WAVE" else {
        throw TranscriptionError.invalidWAV("Not a WAV file")
    }

    // Read format chunk
    let channels: UInt16 = data.withUnsafeBytes { ptr in
        ptr.loadUnaligned(fromByteOffset: 22, as: UInt16.self).littleEndian
    }
    let sampleRate: UInt32 = data.withUnsafeBytes { ptr in
        ptr.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian
    }
    let bitsPerSample: UInt16 = data.withUnsafeBytes { ptr in
        ptr.loadUnaligned(fromByteOffset: 34, as: UInt16.self).littleEndian
    }

    guard channels == 1, sampleRate == 16000, bitsPerSample == 16 else {
        throw TranscriptionError.invalidWAV(
            "Expected 16kHz mono 16-bit, got \(sampleRate)Hz \(channels)ch \(bitsPerSample)bit"
        )
    }

    // Find data chunk (starts at offset 44 for standard WAV)
    let pcmData = data.dropFirst(44)
    let sampleCount = pcmData.count / 2

    var samples = [Float](repeating: 0, count: sampleCount)
    pcmData.withUnsafeBytes { ptr in
        for i in 0..<sampleCount {
            let raw = ptr.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian
            samples[i] = Float(raw) / 32768.0
        }
    }

    return samples
}
