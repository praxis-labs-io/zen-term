import AppLog
import TerminalKit

/// What the user's own config handed to the backend (ZEN-364).
///
/// The chrome resolves its keymap ahead of the responder chain and passes on everything it does not
/// claim, so libghostty's keymap is live underneath ours the whole time. `BackendBindingBaselineTests`
/// pins what sits under our *defaults*, and that is only half the picture: a user keybind moves its
/// action, `KeymapAssembler` then drops that action's defaults, and the freed chord goes to the
/// backend. Rebinding nav to `ctrl+hjkl` is what makes ⌘K clear the scrollback, and no build-time
/// test can see it, because on a default install ⌘K is nav-up and the backend never gets it.
///
/// So this runs at load time instead, against a live surface, over whatever the user's config
/// actually assembled to.
enum BackendShadow {
    /// A chord one of our defaults held that the config freed, and what the backend does with it now.
    struct FreedChord: Equatable {
        let chord: Chord
        /// The default that used to hold the chord, which is also the action the user rebound.
        let action: KeyInterceptor.ReservedChord
        let disposition: ChordDisposition
    }

    /// `probe` is injected the way `KeymapAssembler` injects `canType`, and is `@MainActor` for the
    /// same reason: a plain closure parameter erases the isolation of whatever it was built from,
    /// so an off-main probe would compile clean straight through here (ZEN-31).
    @MainActor
    static func freedChords(
        assembled: [Chord: KeyInterceptor.ReservedChord],
        probe: @MainActor (TerminalKey) -> ChordDisposition
    ) -> [FreedChord] {
        KeymapDefaults.map
            .filter { assembled[$0.key] == nil }
            .compactMap { chord, action -> FreedChord? in
                // No keyCode to ask about, and no keypress on this layout produces the chord either.
                guard let key = TerminalKey(chord: chord) else { return nil }
                let disposition = probe(key)
                guard disposition != .ignores else { return nil }
                return FreedChord(chord: chord, action: action, disposition: disposition)
            }
            .sorted { $0.chord.configToken < $1.chord.configToken }
    }

    @MainActor
    static func report(
        assembled: [Chord: KeyInterceptor.ReservedChord],
        probe: @MainActor (TerminalKey) -> ChordDisposition
    ) {
        for freed in freedChords(assembled: assembled, probe: probe) {
            Log.warning(line(for: freed, in: assembled), category: .keybinds)
        }
    }

    /// The line for one finding, in the config file's vocabulary so the tokens are the ones to grep
    /// for. Its own function because this line is the check's entire output: nothing renders it, so
    /// nothing else would catch it going wrong.
    static func line(
        for freed: FreedChord, in keymap: [Chord: KeyInterceptor.ReservedChord]
    ) -> String {
        let token = freed.action.actionToken
        // A third line can take the chord back off the action the user moved it to, which leaves the
        // action with nothing. Read the winner back from the finished keymap rather than assuming.
        let moved =
            Chord.displayed(freed.action, in: keymap)
            .map { "\(token) moved to \($0.configToken)" } ?? "\(token) has no shortcut"
        return "Keymap: \(moved), so \(freed.chord.configToken) now falls through. "
            + claim(freed.disposition)
    }

    private static func claim(_ disposition: ChordDisposition) -> String {
        switch disposition {
        case .ignores: return "The backend ignores it, so it reaches the program."
        case .claims: return "The backend takes it, so it never reaches the program."
        case .claimsButPasses: return "The backend acts on it and the program still sees it."
        case .mayClaim:
            return "The backend takes it when its own action applies, and otherwise lets it through."
        }
    }
}
