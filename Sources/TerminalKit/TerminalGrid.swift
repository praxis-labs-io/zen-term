/// The screen and its scrollback as cells. Every read is of the screen showing now, and answers nil or `.gone`
/// once the surface is gone.
public protocol TerminalGrid: AnyObject {
    /// Rows in the scrollback and screen together.
    var rowCount: Int { get }
    /// The row at the top of the viewport.
    var viewportTop: Int { get }
    /// The terminal's own cursor.
    var cursorPoint: TerminalGridPoint? { get }
    /// The selection, whoever made it, or nil. A block selection reports its corners.
    var selectionBounds: ClosedRange<TerminalGridPoint>? { get }

    func row(_ index: Int) -> TerminalGridRow?

    /// The text from one cell to another, both included, with soft-wrapped rows joined into one line.
    func text(from start: TerminalGridPoint, to end: TerminalGridPoint) -> String?

    /// Nil when `point` is outside the grid.
    func mark(_ point: TerminalGridPoint) -> TerminalGridMark?

    /// Selects `range` as a drag would, without copying it. Nil clears the selection.
    func setSelection(_ range: ClosedRange<TerminalGridPoint>?)
}
