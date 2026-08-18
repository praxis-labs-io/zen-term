import TerminalKit

/// The built-in theme, Rosé Pine Zen (Moon's palette on Main's darker base), and `current`, the
/// appearance resolved from config at launch. Mirrors `Themes/rose-pine-zen.ghostty`.
enum Theme {
    /// Kept byte-identical to the bundled `rose-pine-zen` file, which `ThemeCatalogTests` locks.
    static let rosePineZen = TerminalTheme(
        // Font is single-sourced on GeneralConfig.builtIn (it's a general-config knob, not a
        // theme key). Safe reference: GeneralConfig.builtIn never touches Theme.
        fontName: GeneralConfig.builtIn.fontName,
        fontSize: GeneralConfig.builtIn.fontSize,
        background: rgb(0x191724),
        foreground: rgb(0xe0def4),
        cursor: rgb(0x6b6790),
        selectionBackground: rgb(0x403d52),
        ansi: [
            rgb(0x393552), rgb(0xeb6f92), rgb(0x3e8fb0), rgb(0xf6c177),  // 0–3
            rgb(0x9ccfd8), rgb(0xc4a7e7), rgb(0xea9a97), rgb(0xe0def4),  // 4–7
            rgb(0x6e6a86), rgb(0xeb6f92), rgb(0x3e8fb0), rgb(0xf6c177),  // 8–11 (bright)
            rgb(0x9ccfd8), rgb(0xc4a7e7), rgb(0xea9a97), rgb(0xe0def4),  // 12–15 (bright)
        ]
    )

    /// The built-in appearance, and the value `current` holds until launch resolves the config.
    static let builtIn = AppTheme(
        terminal: rosePineZen, chrome: ChromeThemeDeriver.derive(from: rosePineZen))

    /// The resolved appearance for this launch, re-resolvable via `reloadCurrent()`. Reads the
    /// general config for the font, so `GeneralConfig.reloadCurrent()` must run first.
    ///
    /// Initialized to the built-in appearance and resolved from disk by
    /// `AppConfig.loadAtLaunch()`, for the same reason `GeneralConfig.current` is.
    static private(set) var current: AppTheme = builtIn

    /// Re-read the theme (and font from the general config) and swap `current`.
    @MainActor
    static func reloadCurrent() { current = ConfigLoader.loadAppTheme() }

    #if DEBUG
        /// Test hook: swap `current` directly so a test can assert theme-reactive views actually
        /// recolor. `current`'s setter is otherwise `private`, and `reloadCurrent()` only re-reads
        /// real config off disk, which leaves recolor behavior unassertable. Pair with a teardown
        /// that restores the original value so the swap can't leak into other tests.
        static func setCurrentForTesting(_ theme: AppTheme) { current = theme }
    #endif

    private static func rgb(_ hex: UInt32) -> TerminalColor {
        TerminalColor(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }
}
