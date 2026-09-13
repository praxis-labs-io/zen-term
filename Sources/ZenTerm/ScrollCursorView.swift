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
            chrome.tint(chrome.accent, alpha: Self.selectionAlpha).setFill()
            fill(Self.rects(for: selection, metrics: metrics))
        } else {
            drawBand(metrics: metrics, row: state.cursorRow)
        }

        drawCursorCell(metrics: metrics, row: state.cursorRow, cells: state.cursorCells)

        if let flash = state.flash, state.flashLevel > 0 {
            chrome.tint(chrome.accent, alpha: Self.flashPeakAlpha * min(1, state.flashLevel))
                .setFill()
            fill(Self.rects(for: flash, metrics: metrics))
        }
    }

    private func drawBand(metrics: TerminalCellMetrics, row: Int) {
        let band = bounds.intersection(
            metrics.cellFrame(row: row, columns: Self.columns(0, metrics.columns - 1, metrics)))
        guard !band.isEmpty else { return }
        Theme.current.chrome.fill(alpha: Self.bandAlpha).setFill()
        NSBezierPath(roundedRect: band, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    // Outlined, not inverted: above libghostty's Metal layer an overlay has no pixels to blend against.
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

    private static func lifted(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            hue: rgb.hueComponent, saturation: rgb.saturationComponent,
            brightness: max(rgb.brightnessComponent, cursorBrightnessFloor), alpha: 1)
    }

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

    private static let bandAlpha: CGFloat = 0.08
    private static let selectionAlpha: CGFloat = 0.28
    private static let cursorStroke: CGFloat = 1.5
    private static let cursorBrightnessFloor: CGFloat = 0.92
    private static let flashPeakAlpha: CGFloat = 0.5
    private static let cornerRadius: CGFloat = 3
    private static let cursorRadius: CGFloat = 2
}
