import TerminalKit

/// zen-term's built-in terminal theme — Rosé Pine Moon (JetBrainsMono Nerd Font Mono,
/// faithful bg/fg/palette) — and `current`, the resolved appearance loaded from
/// `~/.config/zen-term/theme` when present (ZEN-27).
enum Theme {
    static let rosePineMoon = TerminalTheme(
        fontName: "JetBrainsMono Nerd Font Mono",
        fontSize: 14,
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

    /// The resolved appearance for this launch — a user theme from
    /// `~/.config/zen-term/theme`, or the built-in Rosé Pine Moon default. Resolved once,
    /// lazily on first access (before the first window is built). Launch-only in v1.
    static let current: AppTheme = ConfigLoader.loadAppTheme()

    private static func rgb(_ hex: UInt32) -> TerminalColor {
        TerminalColor(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }
}
