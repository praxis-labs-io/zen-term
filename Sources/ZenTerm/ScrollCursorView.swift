import AppKit
import TerminalKit

/// What scroll mode paints over the terminal: the band on its row, the cell its cursor is on, the
/// visual selection, and the pulse a yank leaves behind (ZEN-330, ZEN-331).
///
/// libghostty has no copy mode and no notion of a cursor outside the shell's own, so the chrome
/// draws all of it: translucent fills over the terminal's content, inside the pane's rounded clip.
///
/// It reads its geometry from `TerminalCellMetrics` at draw time rather than caching it, because
/// the row height moves with the font size and the row count moves with every resize. Caching it
/// is how the band ends up a row out of true after a ⌘+.
final class ScrollCursorView: NSView {
    /// Everything the overlay draws, in one value so a redraw is one assignment and the view never
    /// holds half of an update.
    struct State: Equatable {
        var cursor: ScrollCell
        /// The visual selection, or nil in normal mode.
        var selection: TerminalViewportRange?
        /// The span a yank just took, held only for the length of the pulse.
        var flash: TerminalViewportRange?
        /// How far through the pulse we are (1 = full, 0 = gone).
        var flashLevel: CGFloat = 0
    }

    /// Where the grid is, asked for on every layout pass. A closure rather than a stored value so
    /// a resize or a font step is reflected without anything having to remember to push.
    var metrics: (() -> TerminalCellMetrics?)?

    /// Assigned whole, and `redraw()` is what marks the view dirty rather than a `didSet` on this:
    /// the geometry the overlay draws against moves without this value moving with it.
    var state: State?

    /// Ask for a repaint, and count the asks.
    ///
    /// The count is the only way a test can see this happen. A font step changes the cell size
    /// without moving a view's frame or this view's `state`, so nothing observable about the
    /// overlay differs between a redraw that was requested and one that was skipped, and
    /// `needsDisplay` is no help: AppKit holds it true on a view that has never drawn, so it reads
    /// as a pending repaint whether or not anyone asked for one.
    func redraw() {
        redrawRequestsForTesting += 1
        needsDisplay = true
    }

    private(set) var redrawRequestsForTesting = 0

    /// Top-down coordinates, matching how a terminal counts its rows. Without this every row
    /// index would have to be flipped against a row count that changes on resize.
    override var isFlipped: Bool { true }

    /// The pane behind this is a live terminal: clicks, drags and text selection all have to
    /// reach it, so the overlay is paint and nothing else.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        redraw()  // the row's frame is derived from metrics that just moved
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
            accent.withAlphaComponent(Self.bandAlpha).setFill()
            NSBezierPath(roundedRect: band, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
                .fill()
        }

        drawCursorCell(metrics: metrics, accent: accent, cursor: state.cursor)

        // The pulse rides on top of everything else, so a yank confirms the same whether it took a
        // whole row or four characters of one.
        if let flash = state.flash, state.flashLevel > 0 {
            accent.withAlphaComponent(Self.flashPeakAlpha * min(1, state.flashLevel)).setFill()
            fill(Self.rects(for: flash, metrics: metrics))
        }
    }

    /// The cursor cell, stroked rather than filled.
    ///
    /// A real terminal cursor inverts its cell, which an overlay cannot do. A fill solid enough to
    /// read as a cursor over the band would take the character underneath with it, and the point of
    /// a column cursor is to show which character you are on.
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

    /// A span as one rect per row: the first row from its column to the end of the grid, the last
    /// row from the start to its column, and whole rows between them.
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

    /// A column range that is safe to construct. `ClosedRange` traps when its bounds cross, and a
    /// selection's columns cross whenever a motion leaves the cursor behind the anchor on one row.
    private static func columns(_ from: Int, _ through: Int, _ metrics: TerminalCellMetrics)
        -> ClosedRange<Int>
    {
        let last = max(metrics.columns - 1, 0)
        let low = min(max(min(from, through), 0), last)
        let high = min(max(max(from, through), low), last)
        return low...high
    }

    // The diff viewer's cursor row (`DiffLineRowView`): same accent role, same alphas, same radius.
    // Two cursor lines in one app that read differently are two features as far as the eye is
    // concerned. `selectionAlpha` is its non-cursor selected row and `flashPeakAlpha` its yank
    // pulse, which are the same two objects here.
    //
    // Its 1.5pt vertical inset is the one value not carried over. Diff rows are spaced, so the
    // inset reads as a pill; terminal rows are contiguous, so it reads as a band that fails to
    // cover its own line.
    private static let bandAlpha: CGFloat = 0.28
    private static let selectionAlpha: CGFloat = 0.16
    private static let flashPeakAlpha: CGFloat = 0.5
    private static let cornerRadius: CGFloat = 3
    private static let cursorAlpha: CGFloat = 0.9
    private static let cursorStroke: CGFloat = 1
    private static let cursorRadius: CGFloat = 2
}
