import TerminalKit

extension TerminalGrid {
    // The grid's own width, which trails the surface's size until a resize reaches libghostty.
    func lastCell(of row: Int) -> TerminalGridPoint? {
        self.row(row).map { TerminalGridPoint(row: row, column: max($0.cells.count - 1, 0)) }
    }
}
