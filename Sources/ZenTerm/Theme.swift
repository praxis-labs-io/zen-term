import TerminalKit

/// zen-term's built-in terminal theme — Rosé Pine Moon, matching the user's kitty
/// `rose-pine-moon.conf` (JetBrainsMono Nerd Font Mono, faithful bg/fg/palette).
/// (A later epic can parse a live theme file; this is the hardcoded default.)
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

    private static func rgb(_ hex: UInt32) -> TerminalColor {
        TerminalColor(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }
}
