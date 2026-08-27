import CoreGraphics
import TerminalKit

/// Maps a `TerminalTheme` to `ChromeTheme` roles. The accent slots are the exact ANSI
/// colors the chrome used to hardcode by hand (Rosé Pine foam/gold/love/iris/rose in
/// `ToastVariant` and the tab bar), so any ghostty theme recolors the chrome consistently.
enum ChromeThemeDeriver {
    /// `accent` is the one role the user can repoint (`accent-color`) — it is the chrome's
    /// primary and reaches every focus and active surface. Nil keeps `AccentSlot.themeDefault`, so
    /// an unset key derives exactly what it always has. The other roles stay fixed: they are read as
    /// meanings (a warning is not a taste), and `info`/`warning`/`destructive` in particular have to
    /// stay distinguishable from each other whatever the primary becomes.
    static func derive(from terminal: TerminalTheme, accent: AccentSlot? = nil) -> ChromeTheme {
        func slot(_ index: Int) -> TerminalColor {
            terminal.ansi.indices.contains(index) ? terminal.ansi[index] : terminal.foreground
        }
        return ChromeTheme(
            background: terminal.background,
            foreground: terminal.foreground,
            info: slot(4),
            warning: slot(3),
            destructive: slot(1),
            accent: (accent ?? .themeDefault).color(in: terminal),
            attention: slot(6),
            muted: blend(terminal.foreground, terminal.background, 0.55),
            positive: slot(2),
            fillScale: fillScale(for: terminal))
    }

    /// The separation a fill's declared alpha was tuned against. **A fixed anchor, not the
    /// catalog's live median**: deriving it would re-weight every existing theme each time one is
    /// added.
    private static let referenceSeparation: CGFloat = 0.714

    /// Lift this theme's fills so a hairline lands the same visible distance from the background as
    /// it does at `referenceSeparation`. Never scales down, and caps at 1.8; see
    /// `docs/architecture.md` for why both.
    static func fillScale(for terminal: TerminalTheme) -> CGFloat {
        let separation = abs(perceivedLuminance(terminal.foreground) - perceivedLuminance(terminal.background))
        guard separation > 0.01 else { return 1.8 }
        return min(1.8, max(1, referenceSeparation / separation))
    }

    /// The W3C perceived-luminance formula `TerminalColor.isDark` uses, so light/dark decisions and
    /// fill weighting read the same colors the same way.
    private static func perceivedLuminance(_ color: TerminalColor) -> CGFloat {
        0.299 * CGFloat(color.red) / 255 + 0.587 * CGFloat(color.green) / 255
            + 0.114 * CGFloat(color.blue) / 255
    }

    /// Fill in whatever a theme leaves unsaid about the two things drawn *over* its text: a
    /// selection and a search match.
    ///
    /// Search matches are chrome telling you where something is, so they read in the accent the
    /// focus halo and every selected palette row already use. The pair splits by weight rather than
    /// by hue: candidates sit back toward the terminal's own background so a screenful of them is
    /// not a wall, and the selected one takes the accent at full strength and inverts its text.
    ///
    /// A selection instead takes the theme's plain foreground, because it marks text the reader
    /// already chose rather than pointing at something. Naming it at all is the point: left unset,
    /// every cell keeps its own color and the dark ones disappear into the fill.
    ///
    /// Skipped for a theme that names its own, so a hand-written `selection-foreground` wins.
    static func withHighlightColors(_ terminal: TerminalTheme, chrome: ChromeTheme) -> TerminalTheme {
        var theme = terminal
        theme.selectionForeground = terminal.selectionForeground ?? terminal.foreground
        theme.searchForeground = terminal.searchForeground ?? terminal.foreground
        theme.searchBackground =
            terminal.searchBackground ?? blend(chrome.accent, terminal.background, 0.35)
        theme.searchSelectedForeground = terminal.searchSelectedForeground ?? terminal.background
        theme.searchSelectedBackground = terminal.searchSelectedBackground ?? chrome.accent
        return theme
    }

    /// A per-channel weighted average of `a` and `b` at `t` (`t` = 1 keeps `a`, `t` = 0 keeps
    /// `b`), rounded to the nearest 8-bit value. Used to derive `muted` from the foreground/
    /// background pair rather than reproducing a palette color that has no ANSI slot.
    private static func blend(_ a: TerminalColor, _ b: TerminalColor, _ t: Double) -> TerminalColor {
        func mix(_ ca: UInt8, _ cb: UInt8) -> UInt8 {
            UInt8((Double(ca) * t + Double(cb) * (1 - t)).rounded())
        }
        return TerminalColor(
            red: mix(a.red, b.red),
            green: mix(a.green, b.green),
            blue: mix(a.blue, b.blue))
    }
}
