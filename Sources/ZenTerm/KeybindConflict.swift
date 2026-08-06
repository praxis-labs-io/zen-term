import AppLog

/// A chord one config line took from another action, and the two ways to answer it (ZEN-368).
///
/// The config is what created it, so both answers are edits to the config, and both are expressible
/// through `KeymapOverrides` alone. Accept records the loss as deliberate. Revert puts both actions
/// back on their defaults, which makes the offending line equal to the defaults, and
/// `ConfigWriter`'s per-action diff then emits nothing for it. That is the whole mechanism: reverting
/// a line is not a special delete, it is the writer already declining to write what it doesn't need
/// to.
struct KeybindConflict: Equatable {
    /// The action left with no shortcut.
    let loser: KeyInterceptor.ReservedChord
    /// The chord it lost.
    let chord: Chord
    /// What holds the chord now.
    let winner: KeyInterceptor.ReservedChord

    /// Whether there is a line to back out. A float's chord is the `key:` on its own `float =` line
    /// and `key:` is required, so backing one out would mean deleting the float or inventing a new
    /// chord for it. Reverting is offered only when the winner came from a `keybind =` line.
    var isRevertable: Bool {
        if case .toggleToolFloat = winner { return false }
        return true
    }

    /// The conflicts `config` is reporting, in the order the diagnostics collected them.
    ///
    /// Read off the diagnostics rather than recomputed, so the toast, the Settings row and the
    /// launch notice can never disagree about what is outstanding.
    static func all(in config: GeneralConfig) -> [KeybindConflict] {
        config.configDiagnostics.compactMap { diagnostic in
            guard case .keybind(let loser) = diagnostic.scope,
                case .chordTaken(let chord, let winner) = diagnostic.problem
            else { return nil }
            return KeybindConflict(loser: loser, chord: chord, winner: winner)
        }
    }

    /// Record the loss as deliberate: the loser keeps no chord, and the winner keeps the one it took.
    func accepting(_ overrides: KeymapOverrides) -> KeymapOverrides {
        var result = overrides
        result.unbind(loser)
        return result
    }

    /// Put the winner back where it ships. Its line then matches the defaults, so the writer stops
    /// emitting it, and the chord returns to the loser on the next load because no line names the
    /// loser at all and the assembler hands every unmentioned action its defaults.
    ///
    /// Only the winner is touched, deliberately. Binding the loser back too reads as the symmetric
    /// thing to do and is unreachable: a loser already carrying `= none` is not in conflict, because
    /// the unbind frees its default before anything can take it.
    func reverting(_ overrides: KeymapOverrides) -> KeymapOverrides {
        var result = overrides
        result.bind(winner, to: KeymapDefaults.map.filter { $0.value == winner }.keys)
        return result
    }

    /// The title a card or a row leads with: the subject, the way every other notice titles itself.
    var headline: String { "\(CommandCatalog.spec(for: loser).title) has no shortcut" }

    /// The sentence beneath it, in the config file's vocabulary so the token is the one to grep for.
    var message: String { "\(winner.actionToken) took \(chord.displayGlyph) in your config." }
}

/// Writing an answer to a conflict and reloading, so the card and the Shortcuts row share one path
/// rather than each assembling the write for itself (ZEN-368).
@MainActor
enum KeybindConflictResolver {
    /// Record the loss as deliberate, so nothing reports it again.
    @discardableResult
    static func accept(_ conflict: KeybindConflict) -> Bool {
        write(conflict.accepting(KeymapOverrides(config: .current)))
    }

    /// Back out the line that took the chord, restoring both actions.
    @discardableResult
    static func revert(_ conflict: KeybindConflict) -> Bool {
        write(conflict.reverting(KeymapOverrides(config: .current)))
    }

    /// Returns whether the write landed. A failure leaves the conflict reported, which is the honest
    /// outcome for a config file nothing can write to: the card stays, and pressing again retries.
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
