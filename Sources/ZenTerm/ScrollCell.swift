/// One cell on the viewport, row 0 at the top. **A column is a character offset into the row's
/// text, not a cell index**: `ScrollModeController.cells(of:)` converts for the two that need cells.
struct ScrollCell: Equatable {
    var row: Int
    var column: Int

    static let origin = ScrollCell(row: 0, column: 0)
}
