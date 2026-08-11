/// A problem found while loading the config, carried on `GeneralConfig` so a surface can show it
/// in place instead of the user's only clue being a log line nobody reads.
///
/// This widened past the original `.keybind` scope: an invalid scalar (`font-size = bigg`),
/// an out-of-range number, a bad enum value, and a dropped `float =` line all collect here now,
/// each rendered on the Settings row that owns it (or, for the home-less cases, a Tools notice and
/// the reload toast).
///
/// Every diagnostic is still a warning — the config asked for something and got a fallback, not what
/// the user wanted. A severity field would be one case nothing branches on; add it when there's a
/// second severity *and* a reader for it.
///
/// Carries the *facts* and derives every phrasing on read. Three surfaces word the same problem
/// differently — a row has no title to lean on, a single-problem toast has one, a list of problems
/// must not repeat what its own title just said — and a stored sentence can only serve one of them.
/// Deriving also keeps names out of the parse: keybind diagnostics are built inside `KeymapAssembler`,
/// which runs while `GeneralConfig.current` still holds the OLD config, so resolving a float's title
/// back then renders it as its raw id.
struct ConfigDiagnostic: Hashable {
    /// Which surface can render this in place, and what it's about. The associated value names the
    /// subject so a section can match a diagnostic to the row that owns it.
    enum Scope: Hashable {
        /// The action left with no shortcut. Its Shortcuts row carries the message.
        case keybind(KeyInterceptor.ReservedChord)
        /// A scalar/enum config key (`font-size`, `cursor-style`, …). Its form-section row carries
        /// the message; the value is the config token, the thing to grep for in the file.
        case setting(key: String)
        /// A dropped `float =` line. It never became a float, so there's no row — the Tools section
        /// notice and the reload toast carry it. The label is a best-effort name for the file line.
        case toolFloat(label: String)
        /// A surviving float whose sub-field (`width:`/`height:`/`order:`/`persist:`) fell back. The
        /// float still works, so its Tools row carries the message; `id` matches the row, `label`
        /// names it in the toast (resolving the title on read is unreliable — see the type note).
        case toolFloatField(id: String, label: String)
        /// A `keybind =` line that didn't parse to an action. No row to send anyone to; the reload
        /// toast is the only surface.
        case keybindLine
    }

    /// What went wrong — these are different claims and must not share a phrasing.
    enum Problem: Hashable {
        /// Something took the action's last chord, and here's what holds it now.
        case chordTaken(Chord, by: KeyInterceptor.ReservedChord)
        /// A `keybind =` line names a chord the menu bar owns. Taking it would kill the menu item
        /// in silence, because the keymap resolves ahead of `NSApp.sendEvent`, so the bind is
        /// dropped and the action keeps its default. The menu item's name is optional: the set
        /// says a chord is protected, and finding a title for it is a separate question.
        case menuBind(Chord, menuItem: String?)
        /// A surviving float's `key:` names a chord the menu bar owns. The float's twin of
        /// `menuBind`, for the same reason `floatUnusableKey` is `unusableBind`'s: a float message
        /// has no action token to lean on. The float still works; only its chord was refused.
        case floatMenuKey(Chord, menuItem: String?)
        /// A config line names a chord this keyboard can't produce. The line is dead; the action
        /// still has its default.
        case unusableBind(Chord)
        /// A scalar/enum value the parser couldn't read (`expected` names the valid set). The key
        /// fell back to its default.
        case invalidValue(got: String, expected: String)
        /// One item of a list value the parser couldn't read (`expected` names the valid set). Only
        /// that item dropped — the rest of the list still applies, so this must not share
        /// `invalidValue`'s "Using the default." claim.
        case ignoredListItem(got: String, expected: String)
        /// A number outside its range, clamped to the nearest valid extreme.
        case clamped(value: String, to: String)
        /// A `float =` line missing a required field (the config token, e.g. `command:`).
        case floatMissingField(String)
        /// A `float =` line whose `key:` this keyboard can't produce (the raw spec).
        case floatUnusableKey(String)
        /// A `float =` line whose title slugs to a name a built-in float already holds.
        case floatReservedID(String)
        /// A surviving float's sub-field value the parser couldn't read; it fell back to `using`.
        case floatFieldInvalid(field: String, got: String, using: String)
        /// A surviving float's numeric sub-field outside its range, clamped to `to`.
        case floatFieldClamped(field: String, got: String, to: String)
        /// A `keybind =` line that couldn't be parsed (the raw line).
        case unparseableLine(String)
    }

    var scope: Scope
    var problem: Problem

    /// Whether this is a chord conflict, which carries its own answer and its own card.
    ///
    /// A conflict is the one diagnostic a user can resolve from the notice itself: accept the loss,
    /// or revert the line that caused it (`KeybindConflict`). So each gets a toast of its own, while
    /// everything else, having nothing to press, keeps sharing one.
    var isChordConflict: Bool {
        if case .chordTaken = problem { return true }
        return false
    }

    /// Names the menu item that owns a chord, or says "a" when the lookup found no title. The
    /// protected set and the title lookup are separate questions, so the second can come back
    /// empty, and "is the a menu shortcut" is not a sentence.
    private static func owner(_ menuItem: String?) -> String {
        menuItem.map { "the \($0)" } ?? "a"
    }

    /// The action token for a `.keybind` scope, else empty. `.unusableBind` and `.menuBind` only
    /// ever pair with `.keybind`, so this reads the subject its message needs without a scope
    /// switch inside `message`. A float's twin of each carries its own case for that reason.
    private var keybindActionToken: String {
        if case .keybind(let action) = scope { return action.actionToken }
        return ""
    }

    /// The subject's human name — resolved on read; see the type's note. A keybind resolves to its
    /// command title; a setting/float names the config token to grep for.
    var title: String {
        switch scope {
        case .keybind(let action): return CommandCatalog.spec(for: action).title
        case .setting(let key): return key
        case .toolFloat(let label): return label
        case .toolFloatField(_, let label): return label
        case .keybindLine: return "Shortcut"
        }
    }

    /// The one-line claim, for a toast's title.
    var headline: String {
        switch problem {
        case .chordTaken: return "\(title) has no shortcut"
        // Subject alone, the way every toast outside this type titles itself. The claim rides in
        // `message`: a title is one truncating line, and the whole sentence never fits.
        case .menuBind, .floatMenuKey: return title
        case .unusableBind: return "\(title) has an unusable shortcut"
        case .invalidValue: return "\(title) has an invalid value"
        case .ignoredListItem: return "\(title) has an invalid item"
        case .clamped: return "\(title) is out of range"
        case .floatMissingField, .floatUnusableKey, .floatReservedID:
            return "A tool float was ignored"
        case .floatFieldInvalid, .floatFieldClamped: return "\(title) has an invalid setting"
        case .unparseableLine: return "A shortcut line was ignored"
        }
    }

    /// The full sentence, for a Settings row or a single-problem toast — both need to say where this
    /// came from, since nothing around them does. Written in the *config file's* vocabulary
    /// (`⌘⇧\ went to toggle_focus_mode`, `font-size = bigg`), not the UI's, so it names the token to
    /// grep for in the file.
    var message: String {
        switch problem {
        case .chordTaken(let chord, let winner):
            // Present tense, and no "in your config": this reads on the Shortcuts row now, not in a
            // launch warning, so it explains a standing state rather than reporting an event.
            return "\(chord.displayGlyph) goes to \(winner.actionToken)."
        case .menuBind(let chord, let menuItem):
            return "\(keybindActionToken)=\(chord.configToken) is \(Self.owner(menuItem)) menu shortcut. Ignoring it."
        case .floatMenuKey(let chord, let menuItem):
            return "key:\(chord.configToken) is \(Self.owner(menuItem)) menu shortcut. Ignoring it."
        case .unusableBind(let chord):
            return "\(keybindActionToken)=\(chord.configToken) can't be typed on your keyboard. Ignoring it."
        case .invalidValue(let got, let expected):
            return "\(title) = \(got) isn't valid (\(expected)). Using the default."
        case .ignoredListItem(let got, let expected):
            return "\(title): \(got) isn't valid (\(expected)). Ignoring it; the rest still applies."
        case .clamped(let value, let to):
            return "\(title) = \(value) is out of range. Using \(to)."
        case .floatMissingField(let field):
            return "\(title) is missing \(field). Ignoring this tool float."
        case .floatUnusableKey(let key):
            return "\(title) has an unusable key: \(key). Ignoring this tool float."
        case .floatReservedID(let id):
            return "\(title) takes the name \(id), which ZenTerm's built-in Scratch float owns. "
                + "Rename it. Ignoring this tool float."
        case .floatFieldInvalid(let field, let got, let using):
            return "\(title): \(field)\(got) isn't valid. Using \(using)."
        case .floatFieldClamped(let field, let got, let to):
            return "\(title): \(field)\(got) is out of range. Using \(to)."
        case .unparseableLine(let raw):
            // Show the literal `keybind = …` token so the user can grep for it; keep the prose out of
            // the shortcut/keybind word choice so it doesn't fight the "shortcut line" headline.
            return "Couldn't read this line in your config: `keybind = \(raw)`. Ignoring it."
        }
    }

    /// Just what happened, no subject. Terse on purpose: every word pays rent against
    /// `ToastView.messageMaxWidth`, and "went to" spelled out costs ~30pt of a 236pt budget.
    var detail: String {
        switch problem {
        case .chordTaken(let chord, let winner):
            return "\(chord.displayGlyph) → \(winner.actionToken)"
        case .menuBind(let chord, let menuItem), .floatMenuKey(let chord, let menuItem):
            return "\(chord.configToken) → \(menuItem ?? "the menu")"
        case .unusableBind(let chord):
            return "\(chord.configToken) can't be typed"
        case .invalidValue(let got, _):
            return "\(got) isn't valid"
        case .ignoredListItem(let got, _):
            return "\(got) ignored"
        case .clamped(let value, let to):
            return "\(value) → \(to)"
        case .floatMissingField(let field):
            return "missing \(field)"
        case .floatUnusableKey:
            return "key can't be typed"
        case .floatReservedID(let id):
            return "\(id) is reserved"
        case .floatFieldInvalid(let field, let got, _):
            return "\(field)\(got) isn't valid"
        case .floatFieldClamped(let field, let got, let to):
            return "\(field)\(got) → \(to)"
        case .unparseableLine:
            return "couldn't be read"
        }
    }

    /// A list entry: the subject on its own line, its detail indented beneath. Two lines by
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
    /// announce itself: the inline note on a Settings row only reaches someone already looking at
    /// that row, and a user who just broke their config by hand has no reason to go there.
    ///
    /// Every line carries the offending token, because that's what the user greps for in the file.
    /// Naming only the subjects would say something is wrong without saying what to go fix — and the
    /// fix always lives in the config, which is why nothing here points at Settings: a dropped tool
    /// float has no row to send anyone to.
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
