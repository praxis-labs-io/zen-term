/// One cell on the viewport, as scroll mode counts them: row 0 at the top, column 0 at the left
/// (ZEN-331).
///
/// A column is a **character offset into the row's text**, not a cell index. The two agree on
/// everything the C API lets us read: `ghostty_surface_read_text` hands back a string with no
/// per-character cell mapping, so a wide character (CJK, an emoji) occupies two cells while
/// counting as one offset, and the block cursor sits one cell left of true for each one earlier in
/// the row. Closing that gap needs a cell-accurate read libghostty does not expose.
struct ScrollCell: Equatable {
    var row: Int
    var column: Int

    static let origin = ScrollCell(row: 0, column: 0)
}
