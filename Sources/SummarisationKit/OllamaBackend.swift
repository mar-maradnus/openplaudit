/// Ollama HTTP backend for local LLM summarisation.
///
/// Calls the Ollama REST API at localhost:11434. Requires Ollama
/// to be running (`ollama serve`). Falls back gracefully if unavailable.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "summarisation")

/// Ollama API backend for summarisation.
public final class OllamaBackend: SummarisationBackend, @unchecked Sendable {
    public let backendName = "ollama"
    public let modelName: String
    private let baseURL: URL

    public init(model: String = "qwen2.5:3b", baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.modelName = model
        self.baseURL = baseURL
    }

    public func summarise(transcript: String, systemPrompt: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript],
            ],
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300  // 5 minutes for large transcripts
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        log.info("Summarising with Ollama model '\(self.modelName, privacy: .public)'")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarisationError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if httpResponse.statusCode == 404 {
                throw SummarisationError.modelNotFound(modelName)
            }
            throw SummarisationError.networkError("HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummarisationError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

public enum SummarisationError: Error, LocalizedError {
    case modelNotFound(String)
    case networkError(String)
    case invalidResponse
    case templateNotFound(String)
    case backendUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let m): return "Model '\(m)' not found — run 'ollama pull \(m)'"
        case .networkError(let msg): return "Summarisation failed: \(msg)"
        case .invalidResponse: return "Invalid response from summarisation backend"
        case .templateNotFound(let id): return "Template not found: \(id)"
        case .backendUnavailable(let msg): return "Summarisation unavailable: \(msg)"
        }
    }
}
