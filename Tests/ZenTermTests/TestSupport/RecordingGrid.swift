import TerminalKit

// A grid over `RecordingSurface.rows` with no scrollback, so a grid row is a viewport row.
final class RecordingGrid: TerminalGrid {
    private let rows: () -> [String]

    var wrappingRows: Set<Int> = []

    init(rows: @escaping () -> [String]) {
        self.rows = rows
    }

    var rowCount: Int { rows().count }
    var viewportTop: Int { 0 }
    var cursorPoint: TerminalGridPoint? { nil }
    var selectionBounds: ClosedRange<TerminalGridPoint>? { nil }

    func row(_ index: Int) -> TerminalGridRow? { nil }

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

    func mark(_ point: TerminalGridPoint) -> TerminalGridMark? { nil }

    func setSelection(_ range: ClosedRange<TerminalGridPoint>?) {}
}
