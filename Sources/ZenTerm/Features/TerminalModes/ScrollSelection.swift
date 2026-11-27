import TerminalKit

/// The anchor only; the cursor lives on `ScrollModeController`, so there is no second copy to drift.
struct ScrollSelection {
    enum Kind: Equatable {
        case character
        case line
    }

    var kind: Kind
    let anchor: TerminalGridMark

    static func span(
        _ kind: Kind, from anchor: TerminalGridPoint, to cursor: TerminalGridPoint, rowCount: Int,
        row: (Int) -> TerminalGridRow?
    ) -> ClosedRange<TerminalGridPoint> {
        let first = min(anchor, cursor)
        let last = max(anchor, cursor)
        switch kind {
        case .character:
            let isWide =
                row(last.row)?.cells.indices.contains(last.column) == true
                && row(last.row)?.cells[last.column].width == 2
            return first...TerminalGridPoint(row: last.row, column: last.column + (isWide ? 1 : 0))
        case .line:
            let lines = wrappedLines(from: first.row, through: last.row, rowCount: rowCount, row: row)
            let columns = row(lines.upperBound)?.cells.count ?? 1
            let start = TerminalGridPoint(row: lines.lowerBound, column: 0)
            return start...TerminalGridPoint(row: lines.upperBound, column: max(columns - 1, 0))
        }
    }

    static func wrappedLines(
        from top: Int, through bottom: Int, rowCount: Int, row: (Int) -> TerminalGridRow?
    ) -> ClosedRange<Int> {
        var first = top
        while first > 0, row(first)?.continues == true { first -= 1 }
        var last = max(bottom, first)
        while last + 1 < rowCount, row(last)?.wraps == true { last += 1 }
        return first...last
    }
}
