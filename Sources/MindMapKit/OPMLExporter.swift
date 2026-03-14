/// OPML exporter — converts an OutlineNode tree to OPML XML.
///
/// OPML files can be imported into MindNode, XMind, iThoughts, and
/// other mind mapping / outliner tools.

import Foundation

/// Export an OutlineNode tree to OPML format.
public func exportToOPML(_ root: OutlineNode, title: String = "OpenPlaudit Mind Map") -> String {
    var lines: [String] = []
    lines.append("""
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="2.0">
      <head>
        <title>\(escapeXML(title))</title>
        <dateCreated>\(ISO8601DateFormatter().string(from: Date()))</dateCreated>
      </head>
      <body>
    """)

    func renderNode(_ node: OutlineNode, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        if node.children.isEmpty {
            lines.append("\(pad)<outline text=\"\(escapeXML(node.title))\" />")
        } else {
            lines.append("\(pad)<outline text=\"\(escapeXML(node.title))\">")
            for child in node.children {
                renderNode(child, indent: indent + 1)
            }
            lines.append("\(pad)</outline>")
        }
    }

    renderNode(root, indent: 2)

    lines.append("  </body>")
    lines.append("</opml>")

    return lines.joined(separator: "\n")
}

private func escapeXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
