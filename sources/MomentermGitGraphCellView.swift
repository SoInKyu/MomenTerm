//
//  MomentermGitGraphCellView.swift
//  iTerm2
//
//  Cell view used inside the Git Graph window's NSTableView for the leftmost
//  "Graph" column. It draws the dot for the row's commit and the slice of
//  every lane line that passes through this row, so the table renders the
//  DAG with one cell per commit.
//
//  Slice rules per row r:
//    - dot at (laneCenter(commit.column), cellCenter)
//    - if edge starts at this row: vertical from center to bottom in commit's lane
//    - if edge ends at this row: bezier from (from.col, top) to (to.col=commit.col, center)
//    - if edge passes through (from.row < r < to.row): vertical from top to bottom in from.col
//

import AppKit

final class MomentermGitGraphCellView: NSView {

    var layout: MomentermGitGraphLayout = .empty {
        didSet { needsDisplay = true }
    }
    var rowIndex: Int = -1 {
        didSet { needsDisplay = true }
    }

    private let laneSpacing: CGFloat = 14
    private let nodeRadius: CGFloat = 4
    private let leftInset: CGFloat = 8

    /// Stable per-lane palette so each branch line keeps one color for its
    /// whole length; cycles when histories are wider than the palette.
    private static let laneColors: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemPink, .systemTeal, .systemIndigo, .systemBrown,
    ]

    private static func laneColor(_ column: Int) -> NSColor {
        return laneColors[column % laneColors.count]
    }

    override var isFlipped: Bool { true }  // top-down coordinates so y grows downward

    override func draw(_ dirtyRect: NSRect) {
        guard rowIndex >= 0, rowIndex < layout.nodes.count else { return }
        let node = layout.nodes[rowIndex]
        let h = bounds.height
        let cellTop: CGFloat = 0
        let cellBottom: CGFloat = h
        let cellMid: CGFloat = h * 0.5

        // 1. Edges that touch this row, each stroked in its origin lane's color.
        for edge in layout.edges(touchingRow: rowIndex) {
            let fr = edge.from.row
            let tr = edge.to.row
            if fr == tr { continue }

            let fx = laneCenter(column: edge.from.column)
            let tx = laneCenter(column: edge.to.column)

            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round

            if rowIndex == fr {
                // Edge starts here: vertical from this commit's center to bottom in its own lane.
                path.move(to: NSPoint(x: fx, y: cellMid))
                path.line(to: NSPoint(x: fx, y: cellBottom))
            } else if rowIndex == tr {
                // Edge ends here: from (origin lane, top) to (parent lane = this commit's lane, center).
                path.move(to: NSPoint(x: fx, y: cellTop))
                if abs(fx - tx) < 0.5 {
                    path.line(to: NSPoint(x: tx, y: cellMid))
                } else {
                    let cy1 = (cellTop + cellMid) * 0.5
                    path.curve(to: NSPoint(x: tx, y: cellMid),
                               controlPoint1: NSPoint(x: fx, y: cy1),
                               controlPoint2: NSPoint(x: tx, y: cy1))
                }
            } else {
                // Pass-through: straight vertical line through this cell in the origin's lane.
                path.move(to: NSPoint(x: fx, y: cellTop))
                path.line(to: NSPoint(x: fx, y: cellBottom))
            }

            Self.laneColor(edge.from.column).withAlphaComponent(0.85).setStroke()
            path.stroke()
        }

        // 2. Node dot for this row, in its lane's color. HEAD gets an accent ring.
        let nodeX = laneCenter(column: node.column)
        let dotRect = NSRect(x: nodeX - nodeRadius, y: cellMid - nodeRadius,
                             width: nodeRadius * 2, height: nodeRadius * 2)
        let dot = NSBezierPath(ovalIn: dotRect)
        let laneColor = Self.laneColor(node.column)
        laneColor.setFill()
        dot.fill()
        laneColor.setStroke()
        dot.lineWidth = 1.0
        dot.stroke()

        if node.commit.hasHEAD {
            let ringRect = dotRect.insetBy(dx: -2.5, dy: -2.5)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    private func laneCenter(column: Int) -> CGFloat {
        return leftInset + CGFloat(column) * laneSpacing + laneSpacing * 0.5
    }
}
