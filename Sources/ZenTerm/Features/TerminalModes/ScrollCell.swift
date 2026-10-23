/// A column is a character offset into the row's text, not a cell index.
struct ScrollCell: Equatable {
    var row: Int
    var column: Int

    static let origin = ScrollCell(row: 0, column: 0)
}
