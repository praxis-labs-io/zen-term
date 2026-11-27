import TerminalKit

// A grid with no cells: a viewport that can be moved, a cursor, and marks that stay where they were put.
final class StubGrid: TerminalGrid {
    var rowCount = 24
    var viewportTop = 0
    var cursorPoint: TerminalGridPoint? = TerminalGridPoint(row: 0, column: 0)
    var selectionBounds: ClosedRange<TerminalGridPoint>?

    func row(_ index: Int) -> TerminalGridRow? { nil }

    func text(from start: TerminalGridPoint, to end: TerminalGridPoint) -> String? { nil }

    func mark(_ point: TerminalGridPoint) -> TerminalGridMark? {
        TerminalGridMark(read: { .at(point) }, release: {})
    }

    func setSelection(_ range: ClosedRange<TerminalGridPoint>?) { selectionBounds = range }
}
