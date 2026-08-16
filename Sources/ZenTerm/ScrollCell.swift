/// One cell on the viewport: row 0 at the top, column 0 at the left.
///
/// **A column is a character offset into the row's text, not a cell index**, because that is what
/// the motions move by and what vim means by a column. `ScrollModeController.cells(of:)` converts
/// for the two consumers that need cells: the rects drawn and the range read.
struct ScrollCell: Equatable {
    var row: Int
    var column: Int

    static let origin = ScrollCell(row: 0, column: 0)
}
