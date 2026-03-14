/// Hierarchical outline data model for mind map generation.
///
/// A recursive tree structure produced by the LLM from a transcript.
/// Mechanically converted to Draw.io XML, OPML, and Markdown.

import Foundation

/// A node in a hierarchical outline (tree).
public struct OutlineNode: Codable, Equatable, Sendable {
    public var title: String
    public var children: [OutlineNode]

    public init(title: String, children: [OutlineNode] = []) {
        self.title = title
        self.children = children
    }

    /// Total number of nodes in this subtree (including self).
    public var nodeCount: Int {
        1 + children.reduce(0) { $0 + $1.nodeCount }
    }

    /// Maximum depth of the tree (root = 1).
    public var depth: Int {
        if children.isEmpty { return 1 }
        return 1 + children.map(\.depth).max()!
    }
}

/// Parse a markdown outline (indented list) into an OutlineNode tree.
///
/// Expected format:
/// ```
/// - Root Topic
///   - Child 1
///     - Grandchild
///   - Child 2
/// ```
public func parseMarkdownOutline(_ markdown: String) -> OutlineNode? {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        .map { String($0) }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

    guard !lines.isEmpty else { return nil }

    struct ParsedLine {
        let indent: Int
        let text: String
    }

    let parsed: [ParsedLine] = lines.compactMap { line in
        // Count leading spaces (2 or 4 spaces per level)
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = line.count - trimmed.count
        var text = String(trimmed)

        // Strip list marker
        if text.hasPrefix("- ") { text = String(text.dropFirst(2)) }
        else if text.hasPrefix("* ") { text = String(text.dropFirst(2)) }
        else if text.hasPrefix("# ") { text = String(text.dropFirst(2)) }
        else if text.hasPrefix("## ") { text = String(text.dropFirst(3)) }
        else if text.hasPrefix("### ") { text = String(text.dropFirst(4)) }

        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return ParsedLine(indent: indent, text: cleaned)
    }

    guard !parsed.isEmpty else { return nil }

    // Determine indent unit (smallest non-zero indent)
    let indents = parsed.map(\.indent).filter { $0 > 0 }
    let indentUnit = indents.min() ?? 2

    func buildTree(startIndex: Int, parentIndent: Int) -> (nodes: [OutlineNode], nextIndex: Int) {
        var nodes: [OutlineNode] = []
        var i = startIndex
        while i < parsed.count {
            let level = parsed[i].indent
            if level <= parentIndent && i > startIndex { break }

            let node = OutlineNode(title: parsed[i].text)
            i += 1

            // Collect children (lines with deeper indent)
            if i < parsed.count && parsed[i].indent > level {
                let (children, nextI) = buildTree(startIndex: i, parentIndent: level)
                nodes.append(OutlineNode(title: node.title, children: children))
                i = nextI
            } else {
                nodes.append(node)
            }
        }
        return (nodes, i)
    }

    let (topLevel, _) = buildTree(startIndex: 0, parentIndent: -1)

    // If there's a single root, use it; otherwise wrap in a synthetic root
    if topLevel.count == 1 {
        return topLevel[0]
    }
    return OutlineNode(title: "Mind Map", children: topLevel)
}
