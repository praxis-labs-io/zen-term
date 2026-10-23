import AppKit
import TerminalKit

// libghostty has no copy mode, so the chrome draws scroll mode's band, cursor and selection.
final class ScrollCursorView: NSView {
    struct State: Equatable {
        var cursorRow: Int
        var cursorCells: ClosedRange<Int>
        var selection: TerminalViewportRange?
        var flash: TerminalViewportRange?
        var flashLevel: CGFloat = 0
    }

    var metrics: (() -> TerminalCellMetrics?)?

    var state: State?

    // Never key this off `state`: a font step changes cell size while `state` compares equal.
    func redraw() {
        redrawRequestsForTesting += 1
        needsDisplay = true
    }

    private(set) var redrawRequestsForTesting = 0

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        redraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let metrics = metrics?(), metrics.rows > 0, metrics.columns > 0, let state else {
            return
        }
        let chrome = Theme.current.chrome

        if let selection = state.selection {
            chrome.fill(.active).setFill()
            fill(Self.rects(for: selection, metrics: metrics))
        } else {
            drawBand(metrics: metrics, row: state.cursorRow)
        }

        drawCursorCell(metrics: metrics, row: state.cursorRow, cells: state.cursorCells)

        if let flash = state.flash, state.flashLevel > 0 {
            chrome.tint(chrome.accent, alpha: ChromeTheme.flashTint * min(1, state.flashLevel)).setFill()
            fill(Self.rects(for: flash, metrics: metrics))
        }
    }

    private func drawBand(metrics: TerminalCellMetrics, row: Int) {
        let band = bounds.intersection(
            metrics.cellFrame(row: row, columns: Self.columns(0, metrics.columns - 1, metrics)))
        guard !band.isEmpty else { return }
        Theme.current.chrome.fill(.hover).setFill()
        NSBezierPath(rect: band).fill()
    }

    // Outlined, not inverted: above libghostty's Metal layer an overlay has no pixels to blend against.
    private func drawCursorCell(metrics: TerminalCellMetrics, row: Int, cells: ClosedRange<Int>) {
        let cell = bounds.intersection(
            metrics.cellFrame(
                row: row, columns: Self.columns(cells.lowerBound, cells.upperBound, metrics)))
        guard !cell.isEmpty else { return }
        Self.lifted(Theme.current.chrome.cursor.nsColor).setStroke()
        let path = NSBezierPath(rect: cell.insetBy(dx: Self.cursorStroke / 2, dy: Self.cursorStroke / 2))
        path.lineWidth = Self.cursorStroke
        path.stroke()
    }

    private static func lifted(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            hue: rgb.hueComponent, saturation: rgb.saturationComponent,
            brightness: max(rgb.brightnessComponent, cursorBrightnessFloor), alpha: 1)
    }

    private func fill(_ rects: [CGRect]) {
        for rect in rects {
            let clipped = bounds.intersection(rect)
            guard !clipped.isEmpty else { continue }
            NSBezierPath(rect: clipped).fill()
        }
    }

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

    // `ClosedRange` traps on crossed bounds, which a selection's columns hit when the cursor is behind the anchor.
    private static func columns(_ from: Int, _ through: Int, _ metrics: TerminalCellMetrics)
        -> ClosedRange<Int>
    {
        let last = max(metrics.columns - 1, 0)
        let low = min(max(min(from, through), 0), last)
        let high = min(max(max(from, through), low), last)
        return low...high
    }

    private static let cursorStroke: CGFloat = ChromeMetrics.Border.width
    private static let cursorBrightnessFloor: CGFloat = 0.92
}
