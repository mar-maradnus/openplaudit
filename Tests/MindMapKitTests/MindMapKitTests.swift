/// MindMapKit tests — outline parsing, exporters, and MindMapResult.

import Testing
import Foundation
@testable import MindMapKit

@Suite("OutlineNode")
struct OutlineNodeTests {

    @Test func singleNode_hasDepthOne() {
        let node = OutlineNode(title: "Root")
        #expect(node.nodeCount == 1)
        #expect(node.depth == 1)
        #expect(node.children.isEmpty)
    }

    @Test func nodeWithChildren_countsCorrectly() {
        let node = OutlineNode(title: "Root", children: [
            OutlineNode(title: "A"),
            OutlineNode(title: "B", children: [
                OutlineNode(title: "B1"),
                OutlineNode(title: "B2"),
            ]),
        ])
        #expect(node.nodeCount == 5)
        #expect(node.depth == 3)
    }

    @Test func nodeIsCodable() throws {
        let node = OutlineNode(title: "Root", children: [OutlineNode(title: "Child")])
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(OutlineNode.self, from: data)
        #expect(decoded == node)
    }
}

@Suite("parseMarkdownOutline")
struct ParseMarkdownOutlineTests {

    @Test func emptyString_returnsNil() {
        #expect(parseMarkdownOutline("") == nil)
    }

    @Test func whitespaceOnly_returnsNil() {
        #expect(parseMarkdownOutline("   \n  \n") == nil)
    }

    @Test func singleLine_returnsSingleNode() {
        let node = parseMarkdownOutline("- Root Topic")
        #expect(node != nil)
        #expect(node?.title == "Root Topic")
        #expect(node?.children.isEmpty == true)
    }

    @Test func nestedList_parsesCorrectly() {
        let markdown = """
        - Meeting Notes
          - Budget
            - Q3 approved
          - Timeline
        """
        let node = parseMarkdownOutline(markdown)
        #expect(node != nil)
        #expect(node?.title == "Meeting Notes")
        #expect(node?.children.count == 2)
        #expect(node?.children[0].title == "Budget")
        #expect(node?.children[0].children.count == 1)
        #expect(node?.children[0].children[0].title == "Q3 approved")
        #expect(node?.children[1].title == "Timeline")
    }

    @Test func multipleTopLevel_wrapsInSyntheticRoot() {
        let markdown = """
        - Topic A
        - Topic B
        """
        let node = parseMarkdownOutline(markdown)
        #expect(node?.title == "Mind Map")
        #expect(node?.children.count == 2)
    }

    @Test func hashHeaders_parsedAsItems() {
        let markdown = """
        # Main Topic
          - Sub item
        """
        let node = parseMarkdownOutline(markdown)
        #expect(node != nil)
        #expect(node?.title == "Main Topic")
    }

    @Test func asteriskMarkers_supported() {
        let markdown = """
        * Root
          * Child
        """
        let node = parseMarkdownOutline(markdown)
        #expect(node?.title == "Root")
        #expect(node?.children.count == 1)
    }
}

@Suite("DrawioExporter")
struct DrawioExporterTests {

    @Test func singleNode_containsMxCell() {
        let node = OutlineNode(title: "Test Node")
        let xml = exportToDrawio(node)
        #expect(xml.contains("<mxfile>"))
        #expect(xml.contains("Test Node"))
        #expect(xml.contains("mxCell"))
    }

    @Test func xmlEscapesSpecialCharacters() {
        let node = OutlineNode(title: "A & B <> \"quoted\"")
        let xml = exportToDrawio(node)
        #expect(xml.contains("A &amp; B &lt;&gt; &quot;quoted&quot;"))
    }

    @Test func parentChild_producesEdge() {
        let node = OutlineNode(title: "Parent", children: [OutlineNode(title: "Child")])
        let xml = exportToDrawio(node)
        #expect(xml.contains("edge=\"1\""))
        #expect(xml.contains("source="))
        #expect(xml.contains("target="))
    }

    @Test func rootNode_usesRootStyle() {
        let node = OutlineNode(title: "Root")
        let xml = exportToDrawio(node)
        #expect(xml.contains("fillColor=#dae8fc"))
    }
}

@Suite("OPMLExporter")
struct OPMLExporterTests {

    @Test func producesValidOPMLStructure() {
        let node = OutlineNode(title: "Root", children: [OutlineNode(title: "Child")])
        let opml = exportToOPML(node, title: "Test Map")
        #expect(opml.contains("<opml version=\"2.0\">"))
        #expect(opml.contains("<title>Test Map</title>"))
        #expect(opml.contains("outline text=\"Root\""))
        #expect(opml.contains("outline text=\"Child\""))
        #expect(opml.contains("</opml>"))
    }

    @Test func leafNodes_areSelfClosing() {
        let node = OutlineNode(title: "Leaf")
        let opml = exportToOPML(node)
        #expect(opml.contains("outline text=\"Leaf\" />"))
    }
}

@Suite("MarkdownExporter")
struct MarkdownExporterTests {

    @Test func singleNode_singleLine() {
        let node = OutlineNode(title: "Root")
        let md = exportToMarkdown(node)
        #expect(md == "- Root")
    }

    @Test func nestedNodes_indentedCorrectly() {
        let node = OutlineNode(title: "Root", children: [
            OutlineNode(title: "A", children: [OutlineNode(title: "A1")]),
            OutlineNode(title: "B"),
        ])
        let md = exportToMarkdown(node)
        let lines = md.split(separator: "\n").map(String.init)
        #expect(lines[0] == "- Root")
        #expect(lines[1] == "  - A")
        #expect(lines[2] == "    - A1")
        #expect(lines[3] == "  - B")
    }
}

@Suite("MindMapResult")
struct MindMapResultTests {

    @Test func isCodable() throws {
        let result = MindMapResult(markdown: "- Test", model: "qwen2.5:3b")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(MindMapResult.self, from: data)
        #expect(decoded == result)
    }
}
