import Foundation
import PaneKit

enum VimPresence: Equatable {
    case off
    case latched
    case held
}

/// One line of the nvim plugin's protocol; the contract is `docs/nvim-navigator-protocol.md`.
enum NavCommand: Equatable {
    case focus(token: Int, dir: Direction)
    case setVim(token: Int, presence: VimPresence)

    static func decode(_ line: String) -> NavCommand? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
            let wire = try? JSONDecoder().decode(Wire.self, from: data)
        else { return nil }

        switch wire.cmd {
        case "focus":
            guard let dir = wire.dir.flatMap(Self.direction(from:)) else { return nil }
            return .focus(token: wire.pane, dir: dir)
        case "setvim":
            return .setVim(token: wire.pane, presence: Self.presence(from: wire))
        default:
            return nil
        }
    }

    var logLine: String {
        switch self {
        case .focus(let token, let dir): return "focus pane=\(token) dir=\(dir)"
        case .setVim(let token, let presence): return "setvim pane=\(token) vim=\(presence)"
        }
    }

    private static func presence(from wire: Wire) -> VimPresence {
        guard wire.vim == true else { return .off }
        return wire.hold == true ? .held : .latched
    }

    private static func direction(from raw: String) -> Direction? {
        switch raw {
        case "left": return .left
        case "right": return .right
        case "up": return .up
        case "down": return .down
        default: return nil
        }
    }

    private struct Wire: Decodable {
        let cmd: String
        let pane: Int
        let dir: String?
        let vim: Bool?
        let hold: Bool?
    }
}
