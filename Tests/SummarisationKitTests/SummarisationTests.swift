import Testing
import Foundation
@testable import SummarisationKit

@Suite("Summary result types")
struct SummaryResultTests {
    @Test func summaryResultEncodesAsJSON() throws {
        let result = SummaryResult(template: "key_points", model: "test-model", content: "- Point 1\n- Point 2")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SummaryResult.self, from: data)
        #expect(decoded == result)
    }
}

@Suite("Built-in templates")
struct TemplateTests {
    @Test func builtInTemplatesExist() {
        #expect(builtInTemplates.count == 5)
    }

    @Test func allTemplatesHaveIDs() {
        for tmpl in builtInTemplates {
            #expect(!tmpl.id.isEmpty)
            #expect(!tmpl.name.isEmpty)
            #expect(!tmpl.prompt.isEmpty)
            #expect(tmpl.isBuiltIn)
        }
    }

    @Test func templateIDsAreUnique() {
        let ids = builtInTemplates.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func expectedTemplateIDs() {
        let ids = Set(builtInTemplates.map(\.id))
        #expect(ids.contains("key_points"))
        #expect(ids.contains("meeting_minutes"))
        #expect(ids.contains("action_items"))
        #expect(ids.contains("cornell_notes"))
        #expect(ids.contains("soap_notes"))
    }

    @Test func loadCustomTemplatesFromEmptyDir() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let templates = loadCustomTemplates(from: dir)
        #expect(templates.isEmpty)
    }

    @Test func loadCustomTemplatesFromPopulatedDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "Summarise this transcript briefly.".write(to: dir.appendingPathComponent("brief_summary.txt"), atomically: true, encoding: .utf8)
        try "Not a template".write(to: dir.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)

        let templates = loadCustomTemplates(from: dir)
        #expect(templates.count == 1)
        #expect(templates[0].id == "brief_summary")
        #expect(templates[0].name == "Brief Summary")
        #expect(!templates[0].isBuiltIn)
    }
}

@Suite("Summariser")
struct SummariserTests {
    @Test func summariserListsAllTemplates() {
        let backend = MockBackend()
        let summariser = Summariser(backend: backend)
        #expect(summariser.availableTemplates.count == 5)
    }

    @Test func unknownTemplateThrows() async {
        let backend = MockBackend()
        let summariser = Summariser(backend: backend)
        do {
            _ = try await summariser.summarise(transcript: "test", templateID: "nonexistent")
            #expect(Bool(false), "Should have thrown")
        } catch {
            #expect(error is SummarisationError)
        }
    }

    @Test func summariseWithValidTemplate() async throws {
        let backend = MockBackend()
        let summariser = Summariser(backend: backend)
        let result = try await summariser.summarise(transcript: "Hello world", templateID: "key_points")
        #expect(result.template == "key_points")
        #expect(result.model == "mock-model")
        #expect(result.content == "Mock summary of: Hello world")
    }

    @Test func formatTranscriptWithSpeakers() {
        let segments: [(start: Double, end: Double, text: String, speaker: String?)] = [
            (0, 3, "Hello", "Speaker 1"),
            (3, 6, "Hi there", "Speaker 2"),
            (6, 9, "How are you", nil),
        ]
        let formatted = Summariser.formatTranscriptForSummary(segments: segments)
        #expect(formatted.contains("[Speaker 1] Hello"))
        #expect(formatted.contains("[Speaker 2] Hi there"))
        #expect(formatted.contains("How are you"))
        #expect(!formatted.contains("[nil]"))
    }
}

/// Mock backend for testing without network calls.
private struct MockBackend: SummarisationBackend {
    let backendName = "mock"
    let modelName = "mock-model"

    func summarise(transcript: String, systemPrompt: String) async throws -> String {
        "Mock summary of: \(transcript)"
    }
}
