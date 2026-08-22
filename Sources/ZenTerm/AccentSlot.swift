import TerminalKit

/// Which ANSI slot of the active theme the chrome's `accent` role points at, set by
/// `accent-color` in the config.
///
/// The slot is what gets stored — never a resolved color. `accent` is the chrome's primary and is
/// read live at every site that paints it (the pane focus halo and border, primary buttons, focus
/// rings, the tab tracer, activity dots, the brand mark), so keeping this a slot means a theme swap
/// re-resolves all of them against the new palette instead of stranding a color from the old one.
/// Role → slot → color, so a bring-your-own theme recolors it.
///
/// The names are the conventional ANSI hues, not literal color claims — a theme is free to put iris
/// in the magenta slot, which is why the Settings picker shows a swatch beside each name.
enum AccentSlot: String, CaseIterable {
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case brightBlack = "bright-black"
    case brightRed = "bright-red"
    case brightGreen = "bright-green"
    case brightYellow = "bright-yellow"
    case brightBlue = "bright-blue"
    case brightMagenta = "bright-magenta"
    case brightCyan = "bright-cyan"
    case brightWhite = "bright-white"

    /// Index into `TerminalTheme.ansi`: 0–7 normal, 8–15 bright. Spelled out rather than derived
    /// from `allCases` order so reordering a case can't silently repoint every user's accent.
    var ansiIndex: Int {
        switch self {
        case .black: return 0
        case .red: return 1
        case .green: return 2
        case .yellow: return 3
        case .blue: return 4
        case .magenta: return 5
        case .cyan: return 6
        case .white: return 7
        case .brightBlack: return 8
        case .brightRed: return 9
        case .brightGreen: return 10
        case .brightYellow: return 11
        case .brightBlue: return 12
        case .brightMagenta: return 13
        case .brightCyan: return 14
        case .brightWhite: return 15
        }
    }

    /// The default the chrome uses with no `accent-color` set — the slot `ChromeThemeDeriver` has
    /// always derived `accent` from.
    static let themeDefault: AccentSlot = .magenta

    /// Title case, derived from the token so the two can't drift: `bright-cyan` → `Bright cyan`.
    var displayName: String {
        let spaced = rawValue.replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// Groups the Settings picker's rows into "Normal" and "Bright".
    var isBright: Bool { ansiIndex >= 8 }

    /// This slot's color in a given palette. Falls back to the foreground for a theme file that
    /// declared fewer than 16 entries, so a short palette can never trap.
    func color(in terminal: TerminalTheme) -> TerminalColor {
        terminal.ansi.indices.contains(ansiIndex) ? terminal.ansi[ansiIndex] : terminal.foreground
    }
}
