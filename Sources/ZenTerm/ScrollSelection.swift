import TerminalKit

/// The anchor only; the cursor lives on `ScrollModeController`, so there is no second copy to drift.
struct ScrollSelection: Equatable {
    enum Kind: Equatable {
        case character
        case line
    }

    var kind: Kind
    var anchor: ScrollCell

    var anchorLine: String?

    func range(
        to cursor: ScrollCell, columns: Int, cells: (ScrollCell) -> ClosedRange<Int>
    ) -> TerminalViewportRange {
        switch kind {
        case .character:
            let startsAtAnchor =
                anchor.row < cursor.row
                || (anchor.row == cursor.row && anchor.column <= cursor.column)
            let (first, last) = startsAtAnchor ? (anchor, cursor) : (cursor, anchor)
            return TerminalViewportRange(
                startRow: first.row, startColumn: cells(first).lowerBound,
                endRow: last.row, endColumn: cells(last).upperBound)
        case .line:
            return TerminalViewportRange(
                startRow: min(anchor.row, cursor.row), startColumn: 0,
                endRow: max(anchor.row, cursor.row), endColumn: max(columns - 1, 0))
        }
    }
}
