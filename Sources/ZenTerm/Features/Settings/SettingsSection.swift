import AppKit

@MainActor
protocol SettingsSection: AnyObject {
    var navTitle: String { get }
    var onExitToNav: (() -> Void)? { get set }
    func makeDetailView() -> NSView
    func detailStops() -> [NSView]
    func sectionWillHide()
    /// Recolors in place: it runs on hidden sections too, whose in-flight capture has to survive.
    func reapplyTheme()
}

extension SettingsSection {
    func sectionWillHide() {}
    func reapplyTheme() {}
}
