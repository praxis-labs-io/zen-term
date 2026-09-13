import TerminalKit

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

    /// Spelled out rather than derived from `allCases`, so reordering a case cannot repoint a user's accent.
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

    static let themeDefault: AccentSlot = .blue

    var displayName: String {
        let spaced = rawValue.replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    var isBright: Bool { ansiIndex >= 8 }

    /// Falls back to the foreground so a theme with fewer than 16 entries cannot trap.
    func color(in terminal: TerminalTheme) -> TerminalColor {
        terminal.ansi.indices.contains(ansiIndex) ? terminal.ansi[ansiIndex] : terminal.foreground
    }
}
