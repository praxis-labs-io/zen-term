import AppKit
import TerminalKit

/// What scroll mode paints over the terminal: the band on its row, the cell its cursor is on, the
/// visual selection, and the pulse a yank leaves behind.
///
/// libghostty has no copy mode and no cursor outside the shell's own, so the chrome draws all of it.
///
/// Geometry is read from `TerminalCellMetrics` at draw time, never cached: the row height moves with
/// the font size and the row count with every resize.
final class ScrollCursorView: NSView {
    struct State: Equatable {
        var cursor: ScrollCell
        /// The visual selection, or nil in normal mode.
        var selection: TerminalViewportRange?
        /// The span a yank just took, held only for the length of the pulse.
        var flash: TerminalViewportRange?
        /// How far through the pulse we are (1 = full, 0 = gone).
        var flashLevel: CGFloat = 0
    }

    /// A closure, so a resize or a font step reaches the draw without anyone pushing it.
    var metrics: (() -> TerminalCellMetrics?)?

    var state: State?

    /// Mark dirty. **Never key this off a change in `state`**: a font step moves the cell size
    /// without moving the frame or the cursor, so the state compares equal and the band would keep
    /// drawing at the old row height.
    ///
    /// The count exists because `needsDisplay` cannot answer "was a repaint asked for". AppKit
    /// holds it true on a view that has never drawn.
    func redraw() {
        redrawRequestsForTesting += 1
        needsDisplay = true
    }

    private(set) var redrawRequestsForTesting = 0

    /// Top-down, matching how a terminal counts rows.
    override var isFlipped: Bool { true }

    /// The pane behind this is a live terminal: clicks, drags and native selection all have to reach
    /// it, so the overlay is paint and nothing else.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        redraw()  // the row frames come from metrics that just moved
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let metrics = metrics?(), metrics.rows > 0, metrics.columns > 0, let state else {
            return
        }
        let accent = Theme.current.chrome.accent.nsColor

        if let selection = state.selection {
            accent.withAlphaComponent(Self.selectionAlpha).setFill()
            fill(Self.rects(for: selection, metrics: metrics))
        }

        let band = bounds.intersection(metrics.rowFrame(state.cursor.row, width: bounds.width))
        if !band.isEmpty {
            Theme.current.chrome.ink(alpha: Self.bandAlpha).setFill()
            NSBezierPath(roundedRect: band, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
                .fill()
        }

        drawCursorCell(metrics: metrics, accent: accent, cursor: state.cursor)

        if let flash = state.flash, state.flashLevel > 0 {
            accent.withAlphaComponent(Self.flashPeakAlpha * min(1, state.flashLevel)).setFill()
            fill(Self.rects(for: flash, metrics: metrics))
        }
    }

    /// Stroked rather than filled: a real terminal cursor inverts its cell, an overlay cannot, and a
    /// fill solid enough to read as a cursor hides the character it is naming.
    private func drawCursorCell(metrics: TerminalCellMetrics, accent: NSColor, cursor: ScrollCell) {
        let cell = bounds.intersection(
            metrics.cellFrame(
                row: cursor.row, columns: Self.columns(cursor.column, cursor.column, metrics)))
        guard !cell.isEmpty else { return }
        accent.withAlphaComponent(Self.cursorAlpha).setStroke()
        let path = NSBezierPath(
            roundedRect: cell.insetBy(dx: Self.cursorStroke / 2, dy: Self.cursorStroke / 2),
            xRadius: Self.cursorRadius, yRadius: Self.cursorRadius)
        path.lineWidth = Self.cursorStroke
        path.stroke()
    }

    private func fill(_ rects: [CGRect]) {
        for rect in rects {
            let clipped = bounds.intersection(rect)
            guard !clipped.isEmpty else { continue }
            NSBezierPath(
                roundedRect: clipped, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
            ).fill()
        }
    }

    /// One rect per row: the first from its column to the end of the grid, the last from the start
    /// to its column, whole rows between.
    static func rects(for range: TerminalViewportRange, metrics: TerminalCellMetrics) -> [CGRect] {
        let last = max(metrics.columns - 1, 0)
        guard range.endRow > range.startRow else {
            return [
                metrics.cellFrame(
                    row: range.startRow,
                    columns: columns(range.startColumn, range.endColumn, metrics))
            ]
        }
        var rects = [
            metrics.cellFrame(
                row: range.startRow, columns: columns(range.startColumn, last, metrics))
        ]
        for row in (range.startRow + 1)..<range.endRow {
            rects.append(metrics.cellFrame(row: row, columns: columns(0, last, metrics)))
        }
        rects.append(
            metrics.cellFrame(row: range.endRow, columns: columns(0, range.endColumn, metrics)))
        return rects
    }

    /// `ClosedRange` traps when its bounds cross, and a selection's columns cross whenever a motion
    /// leaves the cursor behind the anchor on one row.
    private static func columns(_ from: Int, _ through: Int, _ metrics: TerminalCellMetrics)
        -> ClosedRange<Int>
    {
        let last = max(metrics.columns - 1, 0)
        let low = min(max(min(from, through), 0), last)
        let high = min(max(max(from, through), low), last)
        return low...high
    }

    // `selectionAlpha` and `flashPeakAlpha` match `DiffLineRowView`: same objects, same values.
    // The band deliberately does not. Accent means "this is what a `y` takes", so the band is `ink`
    // and separates by tone rather than by a few points of alpha.
    private static let bandAlpha: CGFloat = 0.08
    private static let selectionAlpha: CGFloat = 0.16
    private static let flashPeakAlpha: CGFloat = 0.5
    private static let cornerRadius: CGFloat = 3
    private static let cursorAlpha: CGFloat = 0.9
    private static let cursorStroke: CGFloat = 1
    private static let cursorRadius: CGFloat = 2
}
