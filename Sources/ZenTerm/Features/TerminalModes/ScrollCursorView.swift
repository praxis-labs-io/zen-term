import AppKit
import TerminalKit

// libghostty has no copy mode, so the chrome draws scroll mode's cursor and yank pulse; ghostty draws the selection.
final class ScrollCursorView: NSView {
    struct Cursor: Equatable {
        var row: Int
        var columns: ClosedRange<Int>
        var glyph: String
        var ink: TerminalColor
    }

    struct State: Equatable {
        var cursor: Cursor?
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
        if let cursor = state.cursor { draw(cursor, metrics: metrics) }

        if let flash = state.flash, state.flashLevel > 0 {
            let chrome = Theme.current.chrome
            chrome.tint(chrome.accent, alpha: ChromeTheme.flashTint * min(1, state.flashLevel)).setFill()
            fill(Self.rects(for: flash, metrics: metrics))
        }
    }

    // Drawn over the glyph libghostty renders: above its Metal layer an overlay has no pixels to blend against.
    private func draw(_ cursor: Cursor, metrics: TerminalCellMetrics) {
        let cell = bounds.intersection(
            metrics.cellFrame(
                row: cursor.row,
                columns: Self.columns(cursor.columns.lowerBound, cursor.columns.upperBound, metrics)))
        guard !cell.isEmpty else { return }
        Theme.current.chrome.cursor.nsColor.setFill()
        NSBezierPath(rect: cell).fill()
        guard !cursor.glyph.isEmpty else { return }
        let glyph = NSAttributedString(
            string: cursor.glyph,
            attributes: [.font: Self.terminalFont, .foregroundColor: cursor.ink.nsColor])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
    }

    // Terminal text, not chrome type: the glyph has to match the cell libghostty drew under it.
    private static var terminalFont: NSFont {
        let size = SessionFontSize.points
        return NSFont(name: Theme.current.terminal.fontName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)  // swiftlint:disable:this untokened_font
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
            let span = columns(range.startColumn, range.endColumn, metrics)
            return [metrics.cellFrame(row: range.startRow, columns: span)]
        }
        var rects = [metrics.cellFrame(row: range.startRow, columns: columns(range.startColumn, last, metrics))]
        for row in (range.startRow + 1)..<range.endRow {
            rects.append(metrics.cellFrame(row: row, columns: columns(0, last, metrics)))
        }
        rects.append(metrics.cellFrame(row: range.endRow, columns: columns(0, range.endColumn, metrics)))
        return rects
    }

    private static func columns(_ first: Int, _ through: Int, _ metrics: TerminalCellMetrics) -> ClosedRange<Int> {
        let last = max(metrics.columns - 1, 0)
        let low = min(max(first, 0), last)
        return low...min(max(through, low), last)
    }
}
