/// One cell on the viewport: row 0 at the top, column 0 at the left.
///
/// **A column is a character offset into the row's text, not a cell index.** `read_text` returns a
/// string with no per-character cell mapping, so a wide character (CJK, emoji) fills two cells while
/// counting as one offset. Everything downstream reads the number as a cell: the cursor draws a cell
/// left of true for each wide character earlier in the row, and a yank ending past one stops short of
/// what was highlighted. A width-aware model would close both.
struct ScrollCell: Equatable {
    var row: Int
    var column: Int

    static let origin = ScrollCell(row: 0, column: 0)
}
