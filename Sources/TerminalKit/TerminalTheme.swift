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
    /// What a backend paints selected text in. Without it every cell keeps its own color, and a
    /// dark one on the selection fill is unreadable.
    ///
    /// Optional on the same terms as the search colors below: nil means "not resolved yet", not
    /// "the backend keeps its defaults".
    public var selectionForeground: TerminalColor?
    /// The 16 ANSI colors in order: 0–7 normal, 8–15 bright.
    public var ansi: [TerminalColor]

    /// How a backend paints scrollback search matches: every match in the first pair, the one
    /// currently selected in the second.
    ///
    /// Optional because a theme file names them or does not, and the chrome fills the gaps: by the
    /// time one of these reaches a surface, `AppTheme` has derived whatever the file left out, so
    /// nil here means "not resolved yet" rather than "the backend keeps its defaults".
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
