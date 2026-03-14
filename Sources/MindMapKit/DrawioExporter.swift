/// Draw.io exporter — converts an OutlineNode tree to mxGraph XML.
///
/// Produces a .drawio file that can be opened in draw.io desktop, VS Code
/// extension, or diagrams.net. Uses a tree layout with automatic positioning.

import Foundation

/// Export an OutlineNode tree to Draw.io XML format.
public func exportToDrawio(_ root: OutlineNode) -> String {
    var cells: [String] = []
    var edges: [String] = []
    var nextID = 2  // 0 and 1 are reserved for root and default parent

    // Layout constants
    let nodeWidth = 160
    let nodeHeight = 40
    let horizontalSpacing = 60
    let verticalSpacing = 30

    struct LayoutNode {
        let id: Int
        let x: Int
        let y: Int
        let title: String
        let isRoot: Bool
    }

    var layoutNodes: [LayoutNode] = []

    // Assign IDs and compute layout using depth-first traversal
    func assignIDs(node: OutlineNode, depth: Int, yOffset: inout Int, parentID: Int?) {
        let id = nextID
        nextID += 1

        let x = depth * (nodeWidth + horizontalSpacing)
        let y = yOffset

        layoutNodes.append(LayoutNode(id: id, x: x, y: y, title: node.title, isRoot: depth == 0))
        yOffset += nodeHeight + verticalSpacing

        if let pid = parentID {
            edges.append(edgeXML(id: nextID, source: pid, target: id))
            nextID += 1
        }

        for child in node.children {
            assignIDs(node: child, depth: depth + 1, yOffset: &yOffset, parentID: id)
        }
    }

    var yPos = 20
    assignIDs(node: root, depth: 0, yOffset: &yPos, parentID: nil)

    for ln in layoutNodes {
        let style = ln.isRoot ? rootStyle : childStyle
        cells.append(cellXML(id: ln.id, value: escapeXML(ln.title), x: ln.x, y: ln.y,
                             width: nodeWidth, height: nodeHeight, style: style))
    }

    return wrapDrawio(cells: cells.joined(separator: "\n") + "\n" + edges.joined(separator: "\n"))
}

// MARK: - XML Generation

private let rootStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;fontStyle=1;fontSize=14;"
private let childStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=#f5f5f5;strokeColor=#666666;fontSize=12;"

private func cellXML(id: Int, value: String, x: Int, y: Int, width: Int, height: Int, style: String) -> String {
    """
          <mxCell id="\(id)" value="\(value)" style="\(style)" vertex="1" parent="1">
            <mxGeometry x="\(x)" y="\(y)" width="\(width)" height="\(height)" as="geometry" />
          </mxCell>
    """
}

private func edgeXML(id: Int, source: Int, target: Int) -> String {
    """
          <mxCell id="\(id)" style="edgeStyle=orthogonalEdgeStyle;" edge="1" source="\(source)" target="\(target)" parent="1">
            <mxGeometry relative="1" as="geometry" />
          </mxCell>
    """
}

private func wrapDrawio(cells: String) -> String {
    """
    <mxfile>
      <diagram name="Mind Map">
        <mxGraphModel>
          <root>
            <mxCell id="0" />
            <mxCell id="1" parent="0" />
    \(cells)
          </root>
        </mxGraphModel>
      </diagram>
    </mxfile>
    """
}

private func escapeXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
