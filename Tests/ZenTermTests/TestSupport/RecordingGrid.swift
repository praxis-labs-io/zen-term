import TerminalKit

// A grid over `RecordingSurface.rows`: one cell per character, a movable viewport, marks that follow dropped rows.
final class RecordingGrid: TerminalGrid {
    private let rows: () -> [String]

    var wrappingRows: Set<Int> = []

    init(rows: @escaping () -> [String]) {
        self.rows = rows
    }

    var rowCount: Int { rows().count }
    var viewportTop = 0
    var droppedRows = 0
    var cursorPoint: TerminalGridPoint? = TerminalGridPoint(row: 0, column: 0)
    private(set) var selectionBounds: ClosedRange<TerminalGridPoint>?

    func row(_ index: Int) -> TerminalGridRow? {
        let rows = rows()
        guard rows.indices.contains(index) else { return nil }
        return TerminalGridRow(
            cells: rows[index].map { TerminalGridCell(text: String($0), width: 1, kind: .output) },
            wraps: wrappingRows.contains(index), continues: wrappingRows.contains(index - 1), prompt: .none)
    }

    func text(from start: TerminalGridPoint, to end: TerminalGridPoint) -> String? {
        let rows = rows()
        let first = min(start, end)
        let last = max(start, end)
        guard rows.indices.contains(first.row), rows.indices.contains(last.row) else { return nil }
        return (first.row...last.row).reduce(into: "") { text, row in
            let line = Array(rows[row])
            let from = row == first.row ? min(first.column, line.count) : 0
            let through = row == last.row ? min(last.column + 1, line.count) : line.count
            text += String(line[from..<max(from, through)])
            if row < last.row, !wrappingRows.contains(row) { text += "\n" }
        }
    }

    func mark(_ point: TerminalGridPoint) -> TerminalGridMark? {
        let droppedAtMark = droppedRows
        return TerminalGridMark(
            read: { [weak self] in
                let dropped = (self?.droppedRows ?? droppedAtMark) - droppedAtMark
                return .at(TerminalGridPoint(row: point.row - dropped, column: point.column))
            }, release: {})
    }

    func setSelection(_ range: ClosedRange<TerminalGridPoint>?) { selectionBounds = range }
}
