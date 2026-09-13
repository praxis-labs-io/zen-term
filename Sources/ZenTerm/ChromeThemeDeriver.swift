import CoreGraphics
import TerminalKit

enum ChromeThemeDeriver {
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

    /// A fixed anchor, not the catalog's median, so adding a theme doesn't re-weight the others.
    private static let referenceSeparation: CGFloat = 0.714

    static func fillScale(for terminal: TerminalTheme) -> CGFloat {
        let separation = abs(perceivedLuminance(terminal.foreground) - perceivedLuminance(terminal.background))
        guard separation > 0.01 else { return 1.8 }
        return min(1.8, max(1, referenceSeparation / separation))
    }

    /// The formula `TerminalColor.isDark` uses, so both read a color the same way.
    private static func perceivedLuminance(_ color: TerminalColor) -> CGFloat {
        0.299 * CGFloat(color.red) / 255 + 0.587 * CGFloat(color.green) / 255
            + 0.114 * CGFloat(color.blue) / 255
    }

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
