/// Import engine — orchestrates file import, conversion, transcription.
///
/// Follows the same @MainActor ObservableObject pattern as MeetingEngine.

import AudioKit
import Combine
import Foundation
import SyncEngine
import TranscriptionKit
import DiarizationKit
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "import")

@MainActor
public final class ImportEngine: ObservableObject {
    @Published public var importState: ImportStatus = .idle
    @Published public var recentImports: [RecentImport] = []

    public let config: AppConfig
    private let transcriber: Transcriber
    private let state: ImportState

    public enum ImportStatus: Equatable {
        case idle
        case converting(filename: String)
        case transcribing(filename: String)
        case error(String)
    }

    public struct RecentImport: Equatable, Sendable {
        public let id: String
        public let date: Date
        public let sourceFilename: String
        public let filename: String
        public let durationSeconds: Double?
        public let transcriptPreview: String?
    }

    public init(config: AppConfig, transcriber: Transcriber) {
        self.config = config
        self.transcriber = transcriber
        self.state = ImportState()
        rebuildRecentImports()
    }

    /// Import one or more audio/video files.
    public func importFiles(_ urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                await importSingleFile(url)
            }
            importState = .idle
        }
    }

    private func importSingleFile(_ sourceURL: URL) async {
        let sourceFilename = sourceURL.lastPathComponent
        let id = UUID().uuidString
        let dirs = getOutputDirs(config)
        let fm = FileManager.default

        // Ensure output directories exist
        try? fm.createDirectory(at: dirs.importAudio, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dirs.importTranscripts, withIntermediateDirectories: true)

        // Generate output filename based on current time
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let baseName = "\(fmt.string(from: Date()))_UTC"
        let wavFilename = "\(baseName).wav"
        let wavPath = dirs.importAudio.appendingPathComponent(wavFilename)

        // Convert to 16kHz mono WAV
        importState = .converting(filename: sourceFilename)
        log.info("Importing \(sourceFilename, privacy: .public)")

        let pcmData: Data
        let duration: Double
        do {
            let result = try convertToMonoPCM(fileURL: sourceURL)
            pcmData = result.pcmData
            duration = result.durationSeconds
        } catch {
            log.error("Conversion failed for \(sourceFilename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            state.markImported(id: id, sourceFilename: sourceFilename, duration: 0, filename: wavFilename)
            state.markFailed(id: id, reason: error.localizedDescription)
            importState = .error("Failed to convert \(sourceFilename)")
            return
        }

        // Write WAV
        do {
            try saveWAV(pcmData, to: wavPath)
        } catch {
            log.error("Failed to write WAV: \(error.localizedDescription, privacy: .public)")
            importState = .error("Failed to save \(wavFilename)")
            return
        }

        state.markImported(id: id, sourceFilename: sourceFilename, duration: duration, filename: wavFilename)

        // Transcribe
        importState = .transcribing(filename: sourceFilename)
        do {
            var result = try await transcriber.transcribe(wavPath: wavPath, language: config.transcription.language)

            // Diarization: assign speaker labels
            if config.diarization.enabled {
                let maxSpk = config.diarization.maxSpeakers
                let wav = wavPath
                let currentResult = result
                result = try await Task.detached {
                    try await SyncEngine.applyDiarization(to: currentResult, wavPath: wav, maxSpeakers: maxSpk)
                }.value
            }

            let jsonPath = dirs.importTranscripts.appendingPathComponent("\(baseName).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(result)
            try jsonData.write(to: jsonPath, options: .atomic)
            state.markTranscribed(id: id)

            log.info("Import complete: \(sourceFilename, privacy: .public) → \(wavFilename, privacy: .public)")

            if config.notifications.enabled {
                sendNotification(
                    title: "Import Complete",
                    body: "\(sourceFilename) transcribed (\(Int(duration))s)"
                )
            }
        } catch {
            log.error("Transcription failed for \(sourceFilename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            state.markFailed(id: id, reason: error.localizedDescription)
            importState = .error("Transcription failed for \(sourceFilename)")
        }

        rebuildRecentImports()
    }

    private func rebuildRecentImports() {
        let dirs = getOutputDirs(config)
        let isoFmt = ISO8601DateFormatter()

        var imports: [RecentImport] = []
        for (id, entry) in state.allEntries {
            guard let importedAt = entry.importedAt,
                  let date = isoFmt.date(from: importedAt),
                  let filename = entry.filename else { continue }

            var preview: String?
            if entry.transcribedAt != nil {
                let baseName = (filename as NSString).deletingPathExtension
                let jsonPath = dirs.importTranscripts.appendingPathComponent("\(baseName).json")
                preview = Self.transcriptPreview(jsonPath)
            }

            imports.append(RecentImport(
                id: id,
                date: date,
                sourceFilename: entry.sourceFilename ?? filename,
                filename: filename,
                durationSeconds: entry.durationSeconds,
                transcriptPreview: preview
            ))
        }

        recentImports = imports.sorted { $0.date > $1.date }.prefix(10).map { $0 }
    }

    static func transcriptPreview(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(57)) + "..."
    }
}
