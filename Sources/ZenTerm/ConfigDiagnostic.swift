/// A problem found while loading the config, carried on `GeneralConfig` so a surface can show it
/// in place instead of the user's only clue being an `NSLog` nobody reads.
///
/// Only `.keybind` diagnostics are collected today (ZEN-142). Every other bad-config path —
/// invalid ints, bad enum values, malformed float lines — still logs and silently falls back;
/// collecting and rendering those is ZEN-154, and is additive to this type.
/// Every diagnostic is a warning today — the config asked for something and got it, just not what
/// the user wanted. A severity field would be one case nothing branches on; ZEN-154 can add it when
/// it has a second severity *and* a reader for it.
struct ConfigDiagnostic: Hashable {
    /// Which surface can render this in place, and what it's about. The associated value names the
    /// subject so a section can match a diagnostic to the row that owns it.
    enum Scope: Hashable {
        /// The action left with no shortcut. Its Settings row carries the message.
        case keybind(KeyInterceptor.ReservedChord)
    }

    var scope: Scope
    /// Written in the *config file's* vocabulary (`⌘⇧\ went to toggle_zoom`), not the UI's, so it
    /// names the exact token to grep for in the file the user has to edit to fix it.
    var message: String

    /// What a reload should announce, or nil to stay quiet. Pure and gated on `alreadyAnnounced`,
    /// extracted from the delegate's observer precisely so this decision is testable — the app
    /// delegate can't be stood up in a test (it binds the nav socket and builds windows at launch),
    /// and a silent-suppression bug here would leave the whole feature dead with tests still green.
    ///
    /// Repeats stay quiet: every in-app write reloads too (a Settings rebind, a float save), and
    /// re-announcing an unchanged conflict on each of those is noise.
    /// Compared as a *set*: diagnostics come out in config-line order, and `ConfigWriter` sorts the
    /// lines it emits, so any Settings write can reorder them. An order-sensitive check would call
    /// that a change and re-announce conflicts the user already dismissed.
    static func announcement(
        for diagnostics: [ConfigDiagnostic], alreadyAnnounced: [ConfigDiagnostic]
    ) -> ToastContent? {
        guard Set(diagnostics) != Set(alreadyAnnounced) else { return nil }
        return toast(for: diagnostics)
    }

    /// The notice for a set of diagnostics, or nil when there's nothing to say. A reload has to
    /// announce itself: the inline note on a Keybinds row only reaches someone already looking at
    /// that row, and a user who just broke their config by hand has no reason to go there.
    /// Every line carries the chord and the winning token, because that pair is the whole point:
    /// it's what the user greps for in the file. Naming only the actions would say something is
    /// wrong without saying what to go fix — and the fix always lives in the config, which is why
    /// nothing here points at Settings: a tool float has no Keybinds row to send anyone to.
    static func toast(for diagnostics: [ConfigDiagnostic]) -> ToastContent? {
        guard !diagnostics.isEmpty else { return nil }
        if diagnostics.count == 1, let only = diagnostics.first {
            return ToastContent(
                variant: .warning, title: "\(title(for: only.scope)) has no shortcut", message: only.message)
        }
        return ToastContent(
            variant: .warning, title: "\(diagnostics.count) actions have no shortcut",
            message: diagnostics.map { "\(title(for: $0.scope)): \($0.message)" }.joined(separator: "\n"))
    }

    private static func title(for scope: Scope) -> String {
        switch scope {
        case .keybind(let action): return CommandCatalog.spec(for: action).title
        }
    }
}
