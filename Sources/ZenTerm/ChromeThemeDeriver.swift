import TerminalKit

/// Maps a `TerminalTheme` to `ChromeTheme` roles. The accent slots are the exact ANSI
/// colors the chrome used to hardcode by hand (Rosé Pine foam/gold/love in `ToastVariant`),
/// so any ghostty theme recolors the chrome consistently.
enum ChromeThemeDeriver {
    static func derive(from terminal: TerminalTheme) -> ChromeTheme {
        func slot(_ index: Int) -> TerminalColor {
            terminal.ansi.indices.contains(index) ? terminal.ansi[index] : terminal.foreground
        }
        return ChromeTheme(
            background: terminal.background,
            foreground: terminal.foreground,
            info: slot(4),
            warning: slot(3),
            destructive: slot(1))
    }
}
