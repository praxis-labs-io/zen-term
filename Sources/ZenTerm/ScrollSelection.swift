import TerminalKit

/// Where `v` or `V` was pressed, and which of vim's two kinds it is.
///
/// The anchor and nothing else. The cursor lives on `ScrollModeController`, which owns it in normal
/// mode too; a second copy here would be one to drift, since every motion would have to write both.
struct ScrollSelection: Equatable {
    enum Kind: Equatable {
        /// `v`. The ends are partial rows, cut at the columns the anchor and cursor sit on.
        case character
        /// `V`. Whole rows, whichever columns the ends happen to be on.
        case line
    }

    var kind: Kind
    /// Fixed for the selection's life: motions move the cursor, never this.
    var anchor: ScrollCell

    /// The span to draw and to yank, ordered so it reads forwards however the motions left it.
    /// `columns` is the grid width, which only `.line` needs.
    func range(to cursor: ScrollCell, columns: Int) -> TerminalViewportRange {
        switch kind {
        case .character:
            return TerminalViewportRange(
                startRow: anchor.row, startColumn: anchor.column,
                endRow: cursor.row, endColumn: cursor.column)
        case .line:
            // Ordered here, not by the range's own init: that pairs each row with its column, so
            // (row 10, col 0) and (row 5, col 79) would come back starting at the last column.
            return TerminalViewportRange(
                startRow: min(anchor.row, cursor.row), startColumn: 0,
                endRow: max(anchor.row, cursor.row), endColumn: max(columns - 1, 0))
        }
    }
}
