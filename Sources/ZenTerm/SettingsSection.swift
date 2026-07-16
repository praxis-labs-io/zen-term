import AppKit

/// One Settings card section: a nav title and a detail view. The card owns nav selection and
/// focus routing; a section supplies its editor and the ordered vertical focus stops within it.
/// PR1 registers only `SettingsKeybindsSection`; later PRs add Terminal, Theme, Layout & Motion.
protocol SettingsSection: AnyObject {
    var navTitle: String { get }
    /// Set by the card: the section calls this when focus should leave the detail pane's first
    /// stop and return to the nav (Left / Shift-Tab), completing the 2D nav ↔ detail model.
    var onExitToNav: (() -> Void)? { get set }
    /// Set by the card: the section calls this to dismiss the whole card (Esc from a detail control).
    func makeDetailView() -> NSView
    /// The detail pane's vertical focus stops, top to bottom (for the shared 2D keyboard model).
    func detailStops() -> [NSView]
    /// Called by the card just before this section's detail view is torn down (a section switch),
    /// so the section can end any in-flight interaction — e.g. an armed keybind capture that would
    /// otherwise leave the app-wide interceptor diverting keystrokes with no visible recording UI.
    func sectionWillHide()
    /// Re-apply the section's theme-dependent colors after a live theme change, recoloring the
    /// mounted detail view IN PLACE (rows, group captions, the persistent Reset-all button/flash).
    /// Must not rebuild the detail view or route through `sectionWillHide()` — the card calls this
    /// on every section (visible or not) instead of `selectSection`, precisely so a hidden
    /// section's in-flight interaction (e.g. an armed keybind capture in another window) survives.
    func reapplyTheme()
}

extension SettingsSection {
    /// Most sections have nothing to tear down; only the keybinds capturer overrides this.
    func sectionWillHide() {}
    /// Default no-op — a section with theme-dependent chrome overrides this.
    func reapplyTheme() {}
}
