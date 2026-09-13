import AppLog

struct KeybindConflict: Equatable {
    let loser: KeyInterceptor.ReservedChord
    let chord: Chord
    let winner: KeyInterceptor.ReservedChord

    /// Only a `keybind =` winner has a line to back out; a float's `key:` is required.
    var isRevertable: Bool {
        if case .toggleToolFloat(let id) = winner { return ToolFloat.isBuiltIn(id) }
        return true
    }

    /// A user float can't accept: `toggle_float:<id>=none` is refused by the assembler.
    var isAcceptable: Bool {
        if case .toggleToolFloat(let id) = loser { return ToolFloat.isBuiltIn(id) }
        return true
    }

    /// Read off the diagnostics so every surface agrees; a conflict with no possible answer is dropped.
    static func all(in config: GeneralConfig) -> [KeybindConflict] {
        config.configDiagnostics.compactMap { diagnostic in
            guard case .keybind(let loser) = diagnostic.scope,
                case .chordTaken(let chord, let winner) = diagnostic.problem
            else { return nil }
            let conflict = KeybindConflict(loser: loser, chord: chord, winner: winner)
            return (conflict.isAcceptable || conflict.isRevertable) ? conflict : nil
        }
    }

    func accepting(_ overrides: KeymapOverrides) -> KeymapOverrides {
        var result = overrides
        result.unbind(loser)
        return result
    }

    /// Drops overrides rather than binding defaults, which would evict whatever else holds those chords.
    func reverting(_ overrides: KeymapOverrides) -> KeymapOverrides {
        var result = overrides
        result.clearOverride(winner)
        return result
    }

    var headline: String { "\(CommandCatalog.spec(for: loser).title) has no shortcut" }

    var message: String { "\(chord.displayGlyph) goes to \(winner.actionToken)." }
}

@MainActor
enum KeybindConflictResolver {
    @discardableResult
    static func accept(_ conflict: KeybindConflict) -> Bool {
        write(conflict.accepting(KeymapOverrides(config: .current)))
    }

    @discardableResult
    static func revert(_ conflict: KeybindConflict) -> Bool {
        write(conflict.reverting(KeymapOverrides(config: .current)))
    }

    private static func write(_ overrides: KeymapOverrides) -> Bool {
        do {
            try ConfigWriter.apply(keybinds: overrides)
        } catch {
            Log.warning(
                "Keymap: couldn't write the config to resolve a shortcut conflict: "
                    + error.localizedDescription, category: .keybinds)
            return false
        }
        AppConfig.reload()
        return true
    }
}
