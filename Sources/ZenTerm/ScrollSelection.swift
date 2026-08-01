import TerminalKit

/// A visual selection in scroll mode: where `v` or `V` was pressed, and which of vim's two kinds it
/// is (ZEN-331).
///
/// It holds the anchor and nothing else. The cursor lives on `ScrollModeController`, which owns it
/// in normal mode too, and a second copy here would be a copy to drift: every motion would have to
/// write both, and the one that forgot would draw a selection ending somewhere the cursor is not.
struct ScrollSelection: Equatable {
    enum Kind: Equatable {
        /// `v`. The ends are partial rows, cut at the columns the anchor and cursor sit on.
        case character
        /// `V`. Whole rows, whichever columns the ends happen to be on.
        case line
    }

    var kind: Kind
    /// Where the selection was opened. Fixed for its life: motions move the cursor, never this.
    var anchor: ScrollCell

    /// The span to draw and to yank, ordered so it reads forwards however the motions left it.
    ///
    /// `columns` is the grid width, which only `.line` needs: it opens both ends to the full row
    /// rather than carrying the columns through, so ordering the rows is the whole of the work.
    func range(to cursor: ScrollCell, columns: Int) -> TerminalViewportRange {
        switch kind {
        case .character:
            return TerminalViewportRange(
                startRow: anchor.row, startColumn: anchor.column,
                endRow: cursor.row, endColumn: cursor.column)
        case .line:
            // Ordered here rather than left to the range's own normalization, which pairs each row
            // with its column: handed (row 10, col 0) and (row 5, col 79) it would swap the columns
            // along with the rows and hand back a span starting at the last column.
            return TerminalViewportRange(
                startRow: min(anchor.row, cursor.row), startColumn: 0,
                endRow: max(anchor.row, cursor.row), endColumn: max(columns - 1, 0))
        }
    }
}
