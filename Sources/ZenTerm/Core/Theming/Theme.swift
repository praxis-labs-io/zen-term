import TerminalKit

enum Theme {
    /// Kept byte-identical to `Themes/zen-ink.ghostty`, which `ThemeCatalogTests` locks.
    static let zenInk = TerminalTheme(
        fontName: GeneralConfig.builtIn.fontName,
        fontSize: GeneralConfig.builtIn.fontSize,
        background: rgb(0x0a0d14),
        foreground: rgb(0xdce3ee),
        cursor: rgb(0x6e9bff),
        selectionBackground: rgb(0x1c2536),
        ansi: [
            rgb(0x161b26), rgb(0xf2707a), rgb(0x6ee6b8), rgb(0xebc17a),
            rgb(0x6e9bff), rgb(0xb58cff), rgb(0x5cc8e0), rgb(0xc3ccda),
            rgb(0x4a5468), rgb(0xff8c94), rgb(0x97f0cf), rgb(0xf7d594),
            rgb(0x93b4ff), rgb(0xc9a8ff), rgb(0x82d9ec), rgb(0xf1f5fb),
        ]
    )

    static let builtIn = AppTheme(
        terminal: zenInk, chrome: ChromeThemeDeriver.derive(from: zenInk))

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
