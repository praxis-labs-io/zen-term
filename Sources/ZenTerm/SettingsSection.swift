import AppKit

/// One Settings card section: a nav title and a detail view. The card owns nav selection and
/// focus routing; a section supplies its editor and the ordered vertical focus stops within it.
/// PR1 registers only `SettingsKeybindsSection`; later PRs add Terminal, Theme, Layout & Motion.
protocol SettingsSection: AnyObject {
    var navTitle: String { get }
    /// Set by the card: the section calls this when focus should leave the detail pane's first
    /// stop and return to the nav (Left / Shift-Tab), completing the 2D nav ↔ detail model.
    var onExitToNav: (() -> Void)? { get set }
    func makeDetailView() -> NSView
    /// The detail pane's vertical focus stops, top to bottom (for the shared 2D keyboard model).
    func detailStops() -> [NSView]
}
