/// Ask AI — chat window for querying transcript content.
///
/// Opens from the menubar or by clicking a recording. Loads the full
/// transcript + summary as context, allows multi-turn conversation.

import AppKit
import SwiftUI
import SummarisationKit
import SyncEngine

struct ChatView: View {
    let chatEngine: ChatEngine
    @State private var inputText = ""
    @State private var messages: [ChatMessage] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                Text("Ask AI — \(chatEngine.recordingName)")
                    .font(.headline)
                Spacer()
                Button("Clear") { clearChat() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if isLoading {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Thinking…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .id("loading")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            Divider()

            // Input
            HStack {
                TextField("Ask about this recording…", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendMessage() }
                    .disabled(isLoading)
                Button("Send") { sendMessage() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { messages = chatEngine.visibleMessages }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        errorMessage = nil
        isLoading = true

        // Optimistically add user message
        messages.append(ChatMessage(role: .user, content: text))

        Task {
            do {
                let response = try await chatEngine.send(text)
                messages = chatEngine.visibleMessages
            } catch {
                errorMessage = error.localizedDescription
                ErrorJournal.shared.log(module: "chat", operation: "send", error: error)
            }
            isLoading = false
        }
    }

    private func clearChat() {
        chatEngine.clearHistory()
        messages = []
        errorMessage = nil
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

/// Open a chat window for the given transcript.
func openChatWindow(
    transcript: String,
    summary: String?,
    recordingName: String,
    config: AppConfig
) -> NSWindow {
    let backend = OllamaBackend(
        model: config.summarisation.model,
        baseURL: URL(string: config.summarisation.ollamaURL)!
    )
    let engine = ChatEngine(
        backend: backend,
        transcript: transcript,
        summary: summary,
        recordingName: recordingName
    )

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.title = "Ask AI — \(recordingName)"
    window.center()
    window.contentView = NSHostingView(rootView: ChatView(chatEngine: engine))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    return window
}
