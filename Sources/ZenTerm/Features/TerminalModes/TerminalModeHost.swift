import AppKit
import TerminalKit

protocol TerminalModeHost: NSView {
    func setScrollCursor(_ state: ScrollCursorView.State?, metrics: @escaping () -> TerminalCellMetrics?)
    @discardableResult func setFindFieldShown(_ shown: Bool) -> FindField?
}
