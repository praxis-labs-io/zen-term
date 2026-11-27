/// One cell of the screen and its scrollback. Row 0 is the oldest scrollback row, so rows renumber when the
/// scrollback drops its oldest rows: hold a `TerminalGridMark` for anything kept past one read.
public struct TerminalGridPoint: Hashable, Comparable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TerminalGridPoint, rhs: TerminalGridPoint) -> Bool {
        lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column < rhs.column)
    }
}
