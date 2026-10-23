import TerminalKit

enum Theme {
    /// Kept byte-identical to `Themes/rose-pine-zen.ghostty`, which `ThemeCatalogTests` locks.
    static let rosePineZen = TerminalTheme(
        fontName: GeneralConfig.builtIn.fontName,
        fontSize: GeneralConfig.builtIn.fontSize,
        background: rgb(0x191724),
        foreground: rgb(0xe0def4),
        cursor: rgb(0x6b6790),
        selectionBackground: rgb(0x403d52),
        ansi: [
            rgb(0x393552), rgb(0xeb6f92), rgb(0x3e8fb0), rgb(0xf6c177),
            rgb(0x9ccfd8), rgb(0xc4a7e7), rgb(0xea9a97), rgb(0xe0def4),
            rgb(0x6e6a86), rgb(0xeb6f92), rgb(0x3e8fb0), rgb(0xf6c177),
            rgb(0x9ccfd8), rgb(0xc4a7e7), rgb(0xea9a97), rgb(0xe0def4),
        ]
    )

    static let builtIn = AppTheme(
        terminal: rosePineZen, chrome: ChromeThemeDeriver.derive(from: rosePineZen))

    static private(set) var current: AppTheme = builtIn

    @MainActor
    static func reloadCurrent() { current = ConfigLoader.loadAppTheme() }

    #if DEBUG
        static func setCurrentForTesting(_ theme: AppTheme) { current = theme }
    #endif

    private static func rgb(_ hex: UInt32) -> TerminalColor {
        TerminalColor(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }
}
