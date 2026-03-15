/// Summary result types and backend protocol for local LLM summarisation.
///
/// SummaryResult is defined in SharedKit for cross-platform use.
/// This file re-exports it and defines the backend protocol (macOS-only).

import Foundation
@_exported import SharedKit

/// Protocol for summarisation backends (Ollama, llama.cpp, etc.).
public protocol SummarisationBackend: Sendable {
    /// Human-readable name of the backend (e.g. "ollama", "llama.cpp").
    var backendName: String { get }
    /// Model identifier used by this backend.
    var modelName: String { get }
    /// Generate a summary from a transcript using the given template prompt.
    func summarise(transcript: String, systemPrompt: String) async throws -> String
}
