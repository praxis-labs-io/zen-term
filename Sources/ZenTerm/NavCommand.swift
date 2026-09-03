import Foundation
import PaneKit

/// How long a pane's nvim flag lives. `held` is owned by the socket connection that
/// declared it and clears when that connection closes; `latched` is the legacy shape that
/// persists until an explicit `off`.
enum VimPresence: Equatable {
    case off
    case latched
    case held
}

/// The newline-delimited JSON wire protocol the nvim plugin speaks to `NavSocketServer`.
/// A pure value + decoder so it's unit-testable without a live socket; the durable
/// contract the plugin repo is written against lives in `docs/nvim-navigator-protocol.md`.
enum NavCommand: Equatable {
    /// Move focus one pane in `dir`, starting from the pane that owns `token` (an nvim
    /// split at its edge handing off to the neighboring ZenTerm pane).
    case focus(token: Int, dir: Direction)
    /// Set how the pane owning `token` advertises nvim.
    case setVim(token: Int, presence: VimPresence)

    /// Decode one JSON line. Returns nil for malformed input, an unknown `cmd`, or an
    /// unrecognized direction — the server drops those silently.
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

    /// One-line rendering for the `.nav` log, so a bug report carries the session's flag
    /// history: which token was flagged nvim, when, and every hand-off in between.
    var logLine: String {
        switch self {
        case .focus(let token, let dir): return "focus pane=\(token) dir=\(dir)"
        case .setVim(let token, let presence): return "setvim pane=\(token) vim=\(presence)"
        }
    }

    /// `hold` only means anything alongside `vim: true`; a client asking to hold a cleared
    /// flag is asking for nothing, so `off` wins.
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
