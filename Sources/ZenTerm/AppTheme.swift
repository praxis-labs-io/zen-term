import TerminalKit

/// The resolved appearance: the terminal theme handed to surfaces, plus the chrome roles
/// derived from it. `Theme.current` holds one for the process.
struct AppTheme: Equatable {
    let terminal: TerminalTheme
    let chrome: ChromeTheme
}
