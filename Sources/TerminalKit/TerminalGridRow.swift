public struct TerminalGridRow: Equatable {
    public enum Prompt: Equatable { case none, start, continuation }

    /// One per column.
    public var cells: [TerminalGridCell]
    /// The line soft-wraps onto the next row.
    public var wraps: Bool
    /// The row carries on a line the row above wrapped.
    public var continues: Bool
    /// Whether the row holds a shell prompt, from shell integration's prompt marks.
    public var prompt: Prompt

    public init(cells: [TerminalGridCell], wraps: Bool, continues: Bool, prompt: Prompt) {
        self.cells = cells
        self.wraps = wraps
        self.continues = continues
        self.prompt = prompt
    }
}
