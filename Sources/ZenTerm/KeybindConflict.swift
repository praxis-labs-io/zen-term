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

    /// Whether the loss can be written down. A float is the mirror of the case above: floats bind
    /// before user keybinds, so a `keybind =` line CAN take a float's chord and leave the float as
    /// the loser. Accepting that would emit `toggle_float:<id>=none`, which the assembler refuses by
    /// design, so the line would sit inert in the config and the card would return at every launch
    /// looking like it had been answered.
    var isAcceptable: Bool {
        if case .toggleToolFloat = loser { return false }
        return true
    }

    /// The conflicts `config` is reporting, in the order the diagnostics collected them.
    ///
    /// Read off the diagnostics rather than recomputed, so the toast, the Settings row and the
    /// launch notice can never disagree about what is outstanding.
    ///
    /// A conflict with no answer at all is dropped: two floats on one chord leave a loser that
    /// cannot be accepted and a winner that cannot be reverted, and a card with no buttons is a
    /// notice that can only be closed forever.
    static func all(in config: GeneralConfig) -> [KeybindConflict] {
        config.configDiagnostics.compactMap { diagnostic in
            guard case .keybind(let loser) = diagnostic.scope,
                case .chordTaken(let chord, let winner) = diagnostic.problem
            else { return nil }
            let conflict = KeybindConflict(loser: loser, chord: chord, winner: winner)
            return (conflict.isAcceptable || conflict.isRevertable) ? conflict : nil
        }
    }

    /// Record the loss as deliberate: the loser keeps no chord, and the winner keeps the one it took.
    func accepting(_ overrides: KeymapOverrides) -> KeymapOverrides {
        var result = overrides
        result.unbind(loser)
        return result
    }

    /// Drop the winner's overrides, so the line that took the chord stops being written. On the next
    /// load nothing names the winner or the loser, and the assembler hands every unmentioned action
    /// its defaults, which is what puts both back.
    ///
    /// Dropping rather than binding the winner to its defaults, which is what this did and is a
    /// quieter way to lose a shortcut: `binds` is keyed by chord and `bind` overwrites, so writing
    /// the winner's default chord in evicts whatever else the user had bound there. That action then
    /// holds nothing, is not in `unbound`, and the writer emits no line for it, so the user answers
    /// one conflict and silently loses a binding they never touched.
    func reverting(_ overrides: KeymapOverrides) -> KeymapOverrides {
        var result = overrides
        result.clearOverride(winner)
        return result
    }

    /// The title a card or a row leads with: the subject, the way every other notice titles itself.
    var headline: String { "\(CommandCatalog.spec(for: loser).title) has no shortcut" }

    /// The sentence beneath it, in the config file's vocabulary so the token is the one to grep for.
    /// Word for word what the Shortcuts row shows (`ConfigDiagnostic.message`): the card and the row
    /// describe one standing fact, and two phrasings of it read as two different problems.
    var message: String { "\(chord.displayGlyph) goes to \(winner.actionToken)." }
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
