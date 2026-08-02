import CoreGraphics

/// A terminal's appearance: the monospaced font and the color palette a backend
/// applies to its view. The chrome supplies one; the backend maps it to its own API.
public struct TerminalTheme: Sendable, Equatable {
    public var fontName: String
    public var fontSize: CGFloat
    public var background: TerminalColor
    public var foreground: TerminalColor
    public var cursor: TerminalColor
    public var selectionBackground: TerminalColor
    /// The 16 ANSI colors in order: 0–7 normal, 8–15 bright.
    public var ansi: [TerminalColor]

    /// How a backend paints scrollback search matches: every match in the first pair, the one
    /// currently selected in the second. Nil leaves the backend on its own defaults, which is what
    /// a backend with no search engine wants and what a theme file that names none should get.
    ///
    /// Opaque colors, no alpha: these reach the grid as flat RGB, so a blend is pre-computed.
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
        self.searchForeground = searchForeground
        self.searchBackground = searchBackground
        self.searchSelectedForeground = searchSelectedForeground
        self.searchSelectedBackground = searchSelectedBackground
    }
}
