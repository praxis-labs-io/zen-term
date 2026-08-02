import TerminalKit

/// The resolved appearance: the terminal theme handed to surfaces, plus the chrome roles
/// derived from it. `Theme.current` holds one for the process.
struct AppTheme: Equatable {
    let terminal: TerminalTheme
    let chrome: ChromeTheme

    /// Derive the chrome roles from the terminal theme, then paint the search highlight colors back
    /// onto the terminal theme from those roles. One call so neither half can be built without the
    /// other: a terminal theme handed to a surface without them renders matches in libghostty's
    /// defaults rather than ours (ZEN-91).
    init(terminal: TerminalTheme, accent: AccentSlot? = nil) {
        let chrome = ChromeThemeDeriver.derive(from: terminal, accent: accent)
        self.chrome = chrome
        self.terminal = ChromeThemeDeriver.withSearchColors(terminal, chrome: chrome)
    }

    init(terminal: TerminalTheme, chrome: ChromeTheme) {
        self.terminal = ChromeThemeDeriver.withSearchColors(terminal, chrome: chrome)
        self.chrome = chrome
    }
}
