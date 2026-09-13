import AppLog
import TerminalKit

/// Logs chords a user rebind freed that libghostty still acts on.
enum BackendShadow {
    struct FreedChord: Equatable {
        let chord: Chord
        let action: KeyInterceptor.ReservedChord
        let disposition: ChordDisposition
    }

    enum Finding: Equatable {
        case backendSilent
        case freed([FreedChord])
    }

    @MainActor
    static func check(
        assembled: [Chord: KeyInterceptor.ReservedChord],
        probe: @MainActor (TerminalKey) -> ChordDisposition
    ) -> Finding {
        guard answers(probe) else { return .backendSilent }
        return .freed(freedChords(assembled: assembled, probe: probe))
    }

    /// `ghostty_surface_new` fails on a locked screen and leaves a surface that ignores every chord.
    @MainActor
    private static func answers(_ probe: @MainActor (TerminalKey) -> ChordDisposition) -> Bool {
        return probe(canary) != .ignores
    }

    /// ⌥← is a terminal encoding the backend keeps for good; a canary we later unbind reads as a dead backend.
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

    static func line(
        for freed: FreedChord, in keymap: [Chord: KeyInterceptor.ReservedChord]
    ) -> String {
        let token = freed.action.actionToken
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
