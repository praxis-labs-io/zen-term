import AppKit
import TerminalKit

/// What scroll mode and the find bar need from whatever card hosts the terminal they are reading:
/// a header to wear while the mode is up, somewhere to hang the scroll cursor, and a find bar.
/// `PanelHostView` (a pane or a drawer) and `SurfaceFloatOverlay` (a tool float) both answer it.
protocol TerminalModeHost: NSView {
    var modeMeta: PanelMeta? { get set }
    func setScrollCursor(_ state: ScrollCursorView.State?, metrics: @escaping () -> TerminalCellMetrics?)
    @discardableResult func setFindBarShown(_ shown: Bool) -> FindBarView?
}
