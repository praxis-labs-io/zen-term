import AppLog
import TerminalKit

/// What the user's own config handed to the backend (ZEN-364).
///
/// The chrome resolves its keymap ahead of the responder chain and passes on everything it does not
/// claim, so libghostty's keymap is live underneath ours the whole time. `BackendShadowSweepTests`
/// pins what libghostty is left holding at all, and that is only half the picture: a user keybind moves its
/// action, `KeymapAssembler` then drops that action's defaults, and the freed chord goes to the
/// backend. No build-time test can see that, because on a default install the chord is still ours.
///
/// So this runs at load time instead, against a live surface, over whatever the user's config
/// actually assembled to.
///
/// **It finds nothing today, and that is the point it has reached rather than a fault.** Rebinding
/// nav to `ctrl+hjkl` used to make ⌘K clear the scrollback; ZEN-369 named `clear_screen` and unbound
/// libghostty's copy, and it was the last chord a ZenTerm default could hand back. What survives in
/// the backend is terminal encoding, which no default sits on. This stays because a ghostty pin bump
/// can add a bind, and a freed chord is where that would first show.
enum BackendShadow {
    /// A chord one of our defaults held that the config freed, and what the backend does with it now.
    struct FreedChord: Equatable {
        let chord: Chord
        /// The default that used to hold the chord, which is also the action the user rebound.
        let action: KeyInterceptor.ReservedChord
        let disposition: ChordDisposition
    }

    /// What the check found, or that it could not ask. Two cases rather than an array, because an
    /// empty array would be the answer to both "your config freed nothing" and "the backend never
    /// answered", and those must not look alike: an empty result is this check's all-clear.
    enum Finding: Equatable {
        /// Nothing down there is answering, so nothing was checked.
        case backendSilent
        case freed([FreedChord])
    }

    /// `probe` is injected the way `KeymapAssembler` injects `canType`, and is `@MainActor` for the
    /// same reason: a plain closure parameter erases the isolation of whatever it was built from,
    /// so an off-main probe would compile clean straight through here (ZEN-31).
    @MainActor
    static func check(
        assembled: [Chord: KeyInterceptor.ReservedChord],
        probe: @MainActor (TerminalKey) -> ChordDisposition
    ) -> Finding {
        guard answers(probe) else { return .backendSilent }
        return .freed(freedChords(assembled: assembled, probe: probe))
    }

    /// Whether the backend is answering at all. A `TerminalSurface` exists before its backend surface
    /// does: `ghostty_surface_new` fails on a locked screen and leaves the object alive and
    /// registered, and every chord then reports `.ignores`.
    ///
    /// ⌥← sends `ESC b` to the program, which is a terminal encoding rather than a chrome action, so
    /// it is one of the binds ZEN-365 keeps for good. **The canary has to come from that permanent
    /// set.** It was ⌘T until ZEN-365 unbound it, and a canary we later unbind reads as a dead
    /// backend forever. `BackendShadowTests` asks a live surface, so the next one to go turns red.
    @MainActor
    private static func answers(_ probe: @MainActor (TerminalKey) -> ChordDisposition) -> Bool {
        return probe(canary) != .ignores
    }

    /// Every keyboard types an arrow, so this resolves without consulting the layout.
    @MainActor
    static var canary: TerminalKey {
        TerminalKey(keyCode: 123, modifiers: .option)
    }

    @MainActor
    private static func freedChords(
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
        switch check(assembled: assembled, probe: probe) {
        case .backendSilent:
            Log.warning(
                "Keymap: the terminal backend isn't answering, so nothing was checked for chords "
                    + "the config freed.", category: .keybinds)
        case .freed(let freed):
            for chord in freed { Log.warning(line(for: chord, in: assembled), category: .keybinds) }
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
