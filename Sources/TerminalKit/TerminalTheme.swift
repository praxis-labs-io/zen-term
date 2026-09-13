import CoreGraphics

public struct TerminalTheme: Sendable, Equatable {
    public var fontName: String
    public var fontSize: CGFloat
    public var background: TerminalColor
    public var foreground: TerminalColor
    public var cursor: TerminalColor
    public var selectionBackground: TerminalColor
    /// Selected text color. Nil means not yet resolved by the chrome, like the search colors.
    public var selectionForeground: TerminalColor?
    /// The 16 ANSI colors: 0 to 7 normal, 8 to 15 bright.
    public var ansi: [TerminalColor]

    /// Search match colors, then the selected match's. Opaque only; nil means not yet resolved.
    public var searchForeground: TerminalColor?
    public var searchBackground: TerminalColor?
    public var searchSelectedForeground: TerminalColor?
    public var searchSelectedBackground: TerminalColor?

    public init(
        fontName: String,
        fontSize: CGFloat,
        background: TerminalColor,
        foreground: TerminalColor,
        cursor: TerminalColor,
        selectionBackground: TerminalColor,
        ansi: [TerminalColor],
        selectionForeground: TerminalColor? = nil,
        searchForeground: TerminalColor? = nil,
        searchBackground: TerminalColor? = nil,
        searchSelectedForeground: TerminalColor? = nil,
        searchSelectedBackground: TerminalColor? = nil
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.ansi = ansi
        self.selectionForeground = selectionForeground
        self.searchForeground = searchForeground
        self.searchBackground = searchBackground
        self.searchSelectedForeground = searchSelectedForeground
        self.searchSelectedBackground = searchSelectedBackground
    }
}
