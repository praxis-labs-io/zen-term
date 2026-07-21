/// A problem found while loading the config, carried on `GeneralConfig` so a surface can show it
/// in place instead of the user's only clue being a log line nobody reads.
///
/// Only `.keybind` diagnostics are collected today (ZEN-142). Every other bad-config path —
/// invalid ints, bad enum values, malformed float lines — still logs and silently falls back;
/// collecting and rendering those is ZEN-154, and is additive to this type.
///
/// Every diagnostic is a warning today — the config asked for something and got it, just not what
/// the user wanted. A severity field would be one case nothing branches on; ZEN-154 can add it when
/// it has a second severity *and* a reader for it.
///
/// Carries the *facts* and derives every phrasing on read. Three surfaces word the same problem
/// differently — a row has no title to lean on, a single-problem toast has one, a list of problems
/// must not repeat what its own title just said — and a stored sentence can only serve one of them.
/// Deriving also keeps names out of the parse: diagnostics are built inside `KeymapAssembler`, which
/// runs while `GeneralConfig.current` still holds the OLD config, so resolving a float's title back
/// then renders it as its raw id.
struct ConfigDiagnostic: Hashable {
    /// Which surface can render this in place, and what it's about. The associated value names the
    /// subject so a section can match a diagnostic to the row that owns it.
    enum Scope: Hashable {
        /// The action left with no shortcut. Its Settings row carries the message.
        case keybind(KeyInterceptor.ReservedChord)
    }

    /// What went wrong — these are different claims and must not share a phrasing.
    enum Problem: Hashable {
        /// Something took the action's last chord, and here's what holds it now.
        case chordTaken(Chord, by: KeyInterceptor.ReservedChord)
        /// A config line names a chord this keyboard can't produce. The line is dead; the action
        /// still has its default.
        case unusableBind(Chord)
    }

    var scope: Scope
    var problem: Problem

    private var action: KeyInterceptor.ReservedChord {
        switch scope {
        case .keybind(let action): return action
        }
    }

    /// The action's human name — resolved on read; see the type's note.
    var title: String { CommandCatalog.spec(for: action).title }

    /// The one-line claim, for a toast's title.
    var headline: String {
        switch problem {
        case .chordTaken: return "\(title) has no shortcut"
        case .unusableBind: return "\(title) has an unusable shortcut"
        }
    }

    /// The full sentence, for a Settings row or a single-problem toast — both need to say where this
    /// came from, since nothing around them does. Written in the *config file's* vocabulary
    /// (`⌘⇧\ went to toggle_focus_mode`), not the UI's, so it names the token to grep for in the file.
    var message: String {
        switch problem {
        case .chordTaken(let chord, let winner):
            return "\(chord.displayGlyph) went to \(winner.actionToken) in your config."
        case .unusableBind(let chord):
            return "\(action.actionToken)=\(chord.configToken) can't be typed on your keyboard. Ignoring it."
        }
    }

    /// Just what happened, no subject. Terse on purpose: every word pays rent against
    /// `ToastView.messageMaxWidth`, and "went to" spelled out costs ~30pt of a 236pt budget.
    var detail: String {
        switch problem {
        case .chordTaken(let chord, let winner):
            return "\(chord.displayGlyph) → \(winner.actionToken)"
        case .unusableBind(let chord):
            return "\(chord.configToken) can't be typed"
        }
    }

    /// A list entry: the action on its own line, its detail indented beneath. Two lines by
    /// *measurement*, not preference — a long action title plus a long token is 284pt against a
    /// 236pt column, so one line can't hold both and the wrap lands mid-phrase. Splitting it puts
    /// the break where it belongs and keeps each line inside the card. Drops the "in your config"
    /// that `message` carries, since the list's own title already said it.
    var summary: String { "\(title)\n  \(detail)" }

    /// What a reload should announce, or nil to stay quiet. Pure and gated on `alreadyAnnounced`,
    /// extracted from the delegate's observer precisely so this decision is testable — the app
    /// delegate can't be stood up in a test (it binds the nav socket and builds windows at launch),
    /// and a silent-suppression bug here would leave the whole feature dead with tests still green.
    ///
    /// Repeats stay quiet: every in-app write reloads too (a Settings rebind, a float save), and
    /// re-announcing an unchanged conflict on each of those is noise. Compared as a *set*:
    /// diagnostics come out in config-line order, and `ConfigWriter` sorts the lines it emits, so any
    /// Settings write can reorder them. An order-sensitive check would call that a change and
    /// re-announce conflicts the user already dismissed.
    static func announcement(
        for diagnostics: [ConfigDiagnostic], alreadyAnnounced: [ConfigDiagnostic]
    ) -> ToastContent? {
        guard Set(diagnostics) != Set(alreadyAnnounced) else { return nil }
        return toast(for: diagnostics)
    }

    /// The notice for a set of diagnostics, or nil when there's nothing to say. A reload has to
    /// announce itself: the inline note on a Keybinds row only reaches someone already looking at
    /// that row, and a user who just broke their config by hand has no reason to go there.
    ///
    /// Every line carries the chord and the offending token, because that pair is the whole point:
    /// it's what the user greps for in the file. Naming only the actions would say something is
    /// wrong without saying what to go fix — and the fix always lives in the config, which is why
    /// nothing here points at Settings: a tool float has no Keybinds row to send anyone to.
    static func toast(for diagnostics: [ConfigDiagnostic]) -> ToastContent? {
        guard !diagnostics.isEmpty else { return nil }
        if diagnostics.count == 1, let only = diagnostics.first {
            return ToastContent(variant: .warning, title: only.headline, message: only.message)
        }
        // Blank line between entries: each is already two lines, so without a gap four lines run
        // together and you can't see where one problem ends and the next begins.
        return ToastContent(
            variant: .warning, title: "\(diagnostics.count) problems in your config",
            message: diagnostics.map(\.summary).joined(separator: "\n\n"))
    }
}
