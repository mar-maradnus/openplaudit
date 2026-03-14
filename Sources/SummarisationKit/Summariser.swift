/// Summariser — orchestrates template selection and backend invocation.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "summarisation")

/// Main entry point for summarising transcripts.
public final class Summariser: @unchecked Sendable {
    private let backend: SummarisationBackend
    private let templates: [SummaryTemplate]

    public init(backend: SummarisationBackend, customTemplatesDir: URL? = nil) {
        self.backend = backend
        var all = builtInTemplates
        if let dir = customTemplatesDir {
            all += loadCustomTemplates(from: dir)
        }
        self.templates = all
    }

    /// All available templates (built-in + custom).
    public var availableTemplates: [SummaryTemplate] { templates }

    /// Summarise a transcript using the specified template.
    ///
    /// - Parameters:
    ///   - transcript: Full transcript text (with speaker labels if available)
    ///   - templateID: Template identifier (e.g. "key_points", "meeting_minutes")
    /// - Returns: SummaryResult with the generated content
    public func summarise(transcript: String, templateID: String) async throws -> SummaryResult {
        guard let template = templates.first(where: { $0.id == templateID }) else {
            throw SummarisationError.templateNotFound(templateID)
        }

        log.info("Summarising with template '\(templateID, privacy: .public)' via \(self.backend.backendName, privacy: .public)")

        let content = try await backend.summarise(transcript: transcript, systemPrompt: template.prompt)

        return SummaryResult(
            template: templateID,
            model: backend.modelName,
            content: content
        )
    }

    /// Format a TranscriptionResult as text suitable for summarisation input.
    /// Includes speaker labels if present.
    public static func formatTranscriptForSummary(segments: [(start: Double, end: Double, text: String, speaker: String?)]) -> String {
        segments.map { seg in
            if let speaker = seg.speaker {
                return "[\(speaker)] \(seg.text)"
            }
            return seg.text
        }.joined(separator: "\n")
    }
}
