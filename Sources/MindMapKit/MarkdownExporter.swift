/// Markdown outline exporter — converts an OutlineNode tree to nested markdown.
///
/// Produces a nested bullet list that can be stored inline in transcript JSON
/// or read in any text editor.

import Foundation

/// Export an OutlineNode tree to a markdown outline.
public func exportToMarkdown(_ root: OutlineNode) -> String {
    var lines: [String] = []

    func render(_ node: OutlineNode, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        lines.append("\(indent)- \(node.title)")
        for child in node.children {
            render(child, depth: depth + 1)
        }
    }

    render(root, depth: 0)
    return lines.joined(separator: "\n")
}
