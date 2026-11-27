public struct TerminalGridCell: Equatable {
    public enum Kind: Equatable { case output, input, prompt }

    /// Empty for a blank cell and for the spacer after a wide character.
    public var text: String
    /// Columns the character covers: 2 for a wide character, 0 for the spacer after it, else 1.
    public var width: Int
    /// From shell integration's prompt marks. Output without them.
    public var kind: Kind

    public init(text: String, width: Int, kind: Kind) {
        self.text = text
        self.width = width
        self.kind = kind
    }
}
