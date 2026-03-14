/// Ask AI — conversational interface for querying transcript content.
///
/// Loads the full transcript + summary as LLM context and allows
/// multi-turn conversation using the same Ollama backend.

import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "chat")

/// A single message in the chat.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: Role
    public let content: String
    public let timestamp: Date

    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public init(role: Role, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

/// Chat engine for conversing with a transcript via a local LLM.
public final class ChatEngine: @unchecked Sendable {
    private let backend: SummarisationBackend
    private var messages: [ChatMessage] = []
    private let lock = NSLock()

    /// The transcript context (loaded once, prepended to every request).
    public let transcriptContext: String
    public let recordingName: String

    public init(backend: SummarisationBackend, transcript: String, summary: String?, recordingName: String) {
        self.backend = backend
        self.recordingName = recordingName

        var context = "Here is a transcript of a recording:\n\n\(transcript)"
        if let summary = summary, !summary.isEmpty {
            context += "\n\nSummary:\n\(summary)"
        }
        self.transcriptContext = context

        let systemMessage = ChatMessage(role: .system, content: """
        You are a helpful assistant that answers questions about a recorded conversation. \
        The user will ask questions about the content, speakers, topics, and details of the recording. \
        Answer based only on the transcript provided. If something is not in the transcript, say so. \
        Be concise and specific. Quote relevant parts of the transcript when helpful.
        """)

        messages = [systemMessage]
    }

    /// All messages in the conversation (excluding system).
    public var visibleMessages: [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { $0.role != .system }
    }

    /// Send a user message and get an assistant response.
    public func send(_ userMessage: String) async throws -> String {
        let userMsg = ChatMessage(role: .user, content: userMessage)

        lock.lock()
        messages.append(userMsg)
        let currentMessages = messages
        lock.unlock()

        // Build the messages array for the API call
        // System prompt + transcript context + conversation history
        let systemPrompt = currentMessages.first(where: { $0.role == .system })?.content ?? ""
        let fullSystemPrompt = "\(systemPrompt)\n\n\(transcriptContext)"

        // Build conversation as a single prompt for the summarisation backend
        var conversationText = ""
        for msg in currentMessages where msg.role != .system {
            switch msg.role {
            case .user:
                conversationText += "User: \(msg.content)\n"
            case .assistant:
                conversationText += "Assistant: \(msg.content)\n"
            case .system:
                break
            }
        }

        log.info("Chat query: \(userMessage.prefix(80), privacy: .public)")

        let response = try await backend.summarise(
            transcript: conversationText,
            systemPrompt: fullSystemPrompt
        )

        let assistantMsg = ChatMessage(role: .assistant, content: response)

        lock.lock()
        messages.append(assistantMsg)
        lock.unlock()

        return response
    }

    /// Clear the conversation history (keeps system message and context).
    public func clearHistory() {
        lock.lock()
        let systemMsg = messages.first(where: { $0.role == .system })
        messages = systemMsg.map { [$0] } ?? []
        lock.unlock()
    }
}
