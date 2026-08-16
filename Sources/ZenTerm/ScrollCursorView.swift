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
        var cursorRow: Int
        /// The cells the cursor's character occupies, so a wide one is outlined whole.
        var cursorCells: ClosedRange<Int>
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
        } else {
            drawBand(metrics: metrics, row: state.cursorRow)
        }

        drawCursorCell(metrics: metrics, row: state.cursorRow, cells: state.cursorCells)

        if let flash = state.flash, state.flashLevel > 0 {
            accent.withAlphaComponent(Self.flashPeakAlpha * min(1, state.flashLevel)).setFill()
            fill(Self.rects(for: flash, metrics: metrics))
        }
    }

    /// The row the cursor is on, drawn only in normal mode.
    ///
    /// A selection says where you are more precisely than the band does, so leaving both up puts two
    /// answers to the same question on one row. It steps aside instead.
    ///
    /// Spans the row's **cells**, not the view: the grid does not fill the view, so a band taking
    /// `bounds.width` overshoots every other rect here into the padding on both sides.
    private func drawBand(metrics: TerminalCellMetrics, row: Int) {
        let band = bounds.intersection(
            metrics.cellFrame(row: row, columns: Self.columns(0, metrics.columns - 1, metrics)))
        guard !band.isEmpty else { return }
        Theme.current.chrome.ink(alpha: Self.bandAlpha).setFill()
        NSBezierPath(roundedRect: band, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    /// The cell the cursor is on, in the terminal's own cursor color.
    ///
    /// The color comes from `Theme.current.terminal.cursor` rather than a chrome role so that the
    /// mode's cursor and the shell's are the same object to the eye: a reader who steps into scroll
    /// mode sees the cursor they were already looking at, moving under different keys.
    ///
    /// Outlined rather than filled, at full strength.
    ///
    /// **An overlay cannot invert.** A real terminal cursor gets its strength by inverting its cell,
    /// which keeps the glyph legible as the background color. This view sits above libghostty's
    /// Metal layer, so its own graphics context holds nothing to blend against: a `.difference` fill
    /// composites over transparent black and returns the cursor color, an opaque block that buries
    /// the character. No blend mode reaches the terminal's pixels, and nothing here can read a glyph
    /// to redraw it, so any fill trades the cursor's presence against the legibility of the
    /// character it names. An outline is the way out of that trade: it carries the full color and
    /// touches no part of the cell the glyph occupies. It is also what ghostty itself draws for an
    /// unfocused cursor, which is the state the surface is in while the mode holds the keyboard.
    private func drawCursorCell(metrics: TerminalCellMetrics, row: Int, cells: ClosedRange<Int>) {
        let cell = bounds.intersection(
            metrics.cellFrame(
                row: row, columns: Self.columns(cells.lowerBound, cells.upperBound, metrics)))
        guard !cell.isEmpty else { return }
        Self.lifted(Theme.current.terminal.cursor.nsColor).setStroke()
        let path = NSBezierPath(
            roundedRect: cell.insetBy(dx: Self.cursorStroke / 2, dy: Self.cursorStroke / 2),
            xRadius: Self.cursorRadius, yRadius: Self.cursorRadius)
        path.lineWidth = Self.cursorStroke
        path.stroke()
    }

    /// The cursor color raised to a brightness floor, keeping its hue.
    ///
    /// A 1.5pt outline is a small amount of color, and a theme whose cursor sits dark leaves it
    /// reading as a smudge. Widening is not the way up: a cell is about 8pt across, so each extra
    /// point takes a quarter of the glyph from either side. Brightness is the axis with room in it.
    ///
    /// Derived from the theme rather than blended toward a literal, so it still follows a
    /// bring-your-own theme instead of drifting toward white on every one of them.
    private static func lifted(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            hue: rgb.hueComponent, saturation: rgb.saturationComponent,
            brightness: max(rgb.brightnessComponent, cursorBrightnessFloor), alpha: 1)
    }

    /// Fill a span's rows so only its outer corners are round.
    ///
    /// Each row grows past its own edge into whichever neighbour continues the span, and is clipped
    /// back to itself: the overhang carries the corner radius out of sight and the interior seams
    /// square off. Rounding every row instead pinches each seam and the span reads as scalloped.
    /// Same trick as `DiffLineRowView.pillRect`.
    private func fill(_ rects: [CGRect]) {
        for (index, rect) in rects.enumerated() {
            let clipped = bounds.intersection(rect)
            guard !clipped.isEmpty else { continue }
            var grown = clipped
            if index > 0 {
                grown.origin.y -= Self.cornerRadius
                grown.size.height += Self.cornerRadius
            }
            if index < rects.count - 1 { grown.size.height += Self.cornerRadius }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clipped).setClip()
            NSBezierPath(roundedRect: grown, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
                .fill()
            NSGraphicsContext.restoreGraphicsState()
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
    // The band deliberately does not: accent means "this is what a `y` takes", so the band is `ink`.
    //
    // The cursor cell carries no alpha: an overlay cannot invert a cell, so it is outlined at full
    // strength rather than washed over. See `drawCursorCell`.
    private static let bandAlpha: CGFloat = 0.08
    private static let selectionAlpha: CGFloat = 0.28
    private static let cursorStroke: CGFloat = 1.5
    private static let cursorBrightnessFloor: CGFloat = 0.92
    private static let flashPeakAlpha: CGFloat = 0.5
    private static let cornerRadius: CGFloat = 3
    private static let cursorRadius: CGFloat = 2
}
