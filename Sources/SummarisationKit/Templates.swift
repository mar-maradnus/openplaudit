/// Built-in summarisation templates and custom template loading.

import Foundation

/// A summarisation template: a name and a system prompt.
public struct SummaryTemplate: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let prompt: String
    public let isBuiltIn: Bool

    public init(id: String, name: String, prompt: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
    }
}

/// Built-in templates shipped with the app.
public let builtInTemplates: [SummaryTemplate] = [
    SummaryTemplate(
        id: "key_points",
        name: "Key Points",
        prompt: """
        You are a concise summariser. Given the transcript below, produce 5-7 bullet points \
        capturing the key points discussed. Each bullet should be one sentence. \
        If speaker labels are present, attribute key statements to speakers. \
        Output only the bullet points, no preamble.
        """,
        isBuiltIn: true
    ),
    SummaryTemplate(
        id: "meeting_minutes",
        name: "Meeting Minutes",
        prompt: """
        You are a professional meeting minutes writer. Given the transcript below, produce \
        structured meeting minutes with these sections:
        - **Attendees** (list speakers)
        - **Agenda** (topics discussed)
        - **Discussion** (key points per topic)
        - **Decisions** (any decisions made)
        - **Next Steps** (action items mentioned)
        Use markdown formatting. Be concise but complete.
        """,
        isBuiltIn: true
    ),
    SummaryTemplate(
        id: "action_items",
        name: "Action Items",
        prompt: """
        You are an action item extractor. Given the transcript below, identify all action items, \
        tasks, commitments, and follow-ups mentioned. Output a markdown table with columns: \
        Task, Owner (speaker if known), Due (if mentioned, otherwise "TBD"). \
        If no action items are found, say "No action items identified."
        """,
        isBuiltIn: true
    ),
    SummaryTemplate(
        id: "cornell_notes",
        name: "Cornell Notes",
        prompt: """
        You are a note-taking assistant using the Cornell Notes method. Given the transcript below, \
        produce notes in three sections:
        - **Cues** (key questions and keywords from the left margin)
        - **Notes** (detailed notes from the right column)
        - **Summary** (2-3 sentence summary at the bottom)
        Use markdown formatting.
        """,
        isBuiltIn: true
    ),
    SummaryTemplate(
        id: "soap_notes",
        name: "SOAP Notes",
        prompt: """
        You are a clinical documentation assistant. Given the transcript below, produce SOAP notes:
        - **Subjective**: Patient's reported symptoms, complaints, and history
        - **Objective**: Observable findings, measurements, test results mentioned
        - **Assessment**: Diagnosis or clinical impression discussed
        - **Plan**: Treatment plan, medications, follow-up discussed
        If the transcript is not a medical consultation, adapt the format to fit the content.
        """,
        isBuiltIn: true
    ),
]

/// Load custom templates from a directory (one .txt file per template).
/// Filename (without extension) becomes the template ID.
public func loadCustomTemplates(from directory: URL) -> [SummaryTemplate] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return [] }

    let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { url -> SummaryTemplate? in
        guard url.pathExtension == "txt" else { return nil }
        guard let prompt = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        let name = id.replacingOccurrences(of: "_", with: " ").capitalized
        return SummaryTemplate(id: id, name: name, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Default directory for custom templates.
public let customTemplatesDir: URL = {
    URL(fileURLWithPath: NSString(string: "~/.config/openplaudit/templates").expandingTildeInPath)
}()
