/// One cell on the viewport: row 0 at the top, column 0 at the left.
///
/// **A column is a character offset into the row's text, not a cell index.** `read_text` returns a
/// string with no per-character cell mapping, so a wide character (CJK, emoji) fills two cells while
/// counting as one offset and the cursor sits a cell left of true. Closing that needs a cell-accurate
/// read libghostty does not expose.
struct ScrollCell: Equatable {
    var row: Int
    var column: Int

    static let origin = ScrollCell(row: 0, column: 0)
}
