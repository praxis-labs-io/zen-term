import TerminalKit

struct AppTheme: Equatable {
    let terminal: TerminalTheme
    let chrome: ChromeTheme

    /// Paints selection and search colors back onto `terminal`, or surfaces fall back to libghostty's defaults.
    init(terminal: TerminalTheme, accent: AccentSlot? = nil) {
        let chrome = ChromeThemeDeriver.derive(from: terminal, accent: accent)
        self.chrome = chrome
        self.terminal = ChromeThemeDeriver.withHighlightColors(terminal, chrome: chrome)
    }

    init(terminal: TerminalTheme, chrome: ChromeTheme) {
        self.terminal = ChromeThemeDeriver.withHighlightColors(terminal, chrome: chrome)
        self.chrome = chrome
    }
}
