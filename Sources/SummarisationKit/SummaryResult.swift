/// Summary result types and backend protocol for local LLM summarisation.

import Foundation

/// Result of summarising a transcript.
public struct SummaryResult: Codable, Sendable, Equatable {
    public let template: String
    public let model: String
    public let content: String

    public init(template: String, model: String, content: String) {
        self.template = template
        self.model = model
        self.content = content
    }
}

/// Protocol for summarisation backends (Ollama, llama.cpp, etc.).
public protocol SummarisationBackend: Sendable {
    /// Human-readable name of the backend (e.g. "ollama", "llama.cpp").
    var backendName: String { get }
    /// Model identifier used by this backend.
    var modelName: String { get }
    /// Generate a summary from a transcript using the given template prompt.
    func summarise(transcript: String, systemPrompt: String) async throws -> String
}
