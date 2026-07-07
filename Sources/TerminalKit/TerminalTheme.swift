import CoreGraphics

/// A terminal's appearance: the monospaced font and the color palette a backend
/// applies to its view. The chrome supplies one; the backend maps it to its own API.
public struct TerminalTheme: Sendable {
    public var fontName: String
    public var fontSize: CGFloat
    public var background: TerminalColor
    public var foreground: TerminalColor
    public var cursor: TerminalColor
    public var selectionBackground: TerminalColor
    /// The 16 ANSI colors in order: 0–7 normal, 8–15 bright.
    public var ansi: [TerminalColor]

    public init(
        fontName: String,
        fontSize: CGFloat,
        background: TerminalColor,
        foreground: TerminalColor,
        cursor: TerminalColor,
        selectionBackground: TerminalColor,
        ansi: [TerminalColor]
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.ansi = ansi
    }
}
