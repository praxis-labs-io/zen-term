import AppKit
import TerminalKit

protocol TerminalModeHost: NSView {
    func setScrollCursor(
        _ state: ScrollCursorView.State?, readout: String?, metrics: @escaping () -> TerminalCellMetrics?)
    @discardableResult func setFindFieldShown(_ shown: Bool) -> FindField?
}
