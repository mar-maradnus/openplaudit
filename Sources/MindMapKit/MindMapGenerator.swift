/// Mind map generator — uses an LLM to produce a structured outline from a transcript.
///
/// Sends the transcript to Ollama and asks for a markdown outline.
/// The outline is then parsed into an OutlineNode tree and exported
/// to Draw.io, OPML, and Markdown formats.

import Foundation
import SummarisationKit
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "mindmap")

/// Result of mind map generation.
public struct MindMapResult: Codable, Equatable, Sendable {
    public let markdown: String
    public let model: String

    public init(markdown: String, model: String) {
        self.markdown = markdown
        self.model = model
    }
}

private let mindMapPrompt = """
You are a mind map generator. Given a transcript of a recording, produce a hierarchical \
outline that captures the key topics, subtopics, and important details.

Rules:
- Use markdown nested bullet list format (- for items, 2-space indent for children)
- Start with one root topic that summarizes the overall subject
- Use 2-4 main branches (key themes or topics discussed)
- Each branch should have 2-5 sub-items
- Keep items concise (5-10 words each)
- Do not include timestamps or speaker labels
- Do not include any explanation — output ONLY the markdown outline

Example output:
- Quarterly Business Review
  - Revenue Performance
    - Q3 revenue up 15% YoY
    - Enterprise segment strongest
    - APAC region underperforming
  - Product Updates
    - Mobile app v2.0 launched
    - API response time improved 40%
  - Team Updates
    - Three new hires in engineering
    - Design team restructuring
"""

/// Generate a mind map outline from a transcript using an LLM.
public struct MindMapGenerator {

    /// Generate a mind map from a transcript.
    ///
    /// - Parameters:
    ///   - transcript: Formatted transcript text
    ///   - backend: Summarisation backend (Ollama) to use
    /// - Returns: MindMapResult containing the markdown outline
    public static func generate(
        transcript: String,
        backend: SummarisationBackend
    ) async throws -> MindMapResult {
        log.info("Generating mind map via \(backend.backendName, privacy: .public)")

        let markdown = try await backend.summarise(
            transcript: transcript,
            systemPrompt: mindMapPrompt
        )

        return MindMapResult(markdown: markdown, model: backend.modelName)
    }

    /// Generate a mind map and export to all formats.
    ///
    /// Returns the parsed outline tree (nil if LLM output couldn't be parsed),
    /// and writes .drawio and .opml files alongside the transcript.
    public static func generateAndExport(
        transcript: String,
        backend: SummarisationBackend,
        outputDir: URL,
        baseName: String
    ) async throws -> (result: MindMapResult, outline: OutlineNode?) {
        let result = try await generate(transcript: transcript, backend: backend)

        guard let outline = parseMarkdownOutline(result.markdown) else {
            log.warning("Could not parse LLM outline into tree structure")
            return (result, nil)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Draw.io
        let drawioXML = exportToDrawio(outline)
        let drawioPath = outputDir.appendingPathComponent("\(baseName).drawio")
        try drawioXML.write(to: drawioPath, atomically: true, encoding: .utf8)

        // OPML
        let opmlXML = exportToOPML(outline, title: outline.title)
        let opmlPath = outputDir.appendingPathComponent("\(baseName).opml")
        try opmlXML.write(to: opmlPath, atomically: true, encoding: .utf8)

        log.info("Mind map exported: \(baseName).drawio, \(baseName).opml")
        return (result, outline)
    }
}
