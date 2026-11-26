import AppKit
import TerminalKit

protocol TerminalModeHost: NSView {
    func setScrollCursor(_ state: ScrollCursorView.State?, metrics: @escaping () -> TerminalCellMetrics?)
    @discardableResult func setFindBarShown(_ shown: Bool) -> FindBarView?
}
