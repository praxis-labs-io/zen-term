import AppKit
import XCTest

@testable import ZenTerm

final class TooltipPresenterTests: WindowTestCase {
    func test_presentingATooltip_conflictsWithNoConstraint() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let source = NSView(frame: NSRect(x: 400, y: 300, width: 24, height: 24))
        window.contentView?.addSubview(source)

        let conflicts = constraintConflicts {
            TooltipPresenter.shared.scheduleShow(for: source, label: "New tab", shortcut: "⌘T")
            waitUntil(TooltipPresenter.shared.tooltipForTesting != nil, "the tooltip")
        }
        TooltipPresenter.shared.dismiss()

        XCTAssertEqual(conflicts, [])
    }

    func test_aTooltip_fadesInAndOutRatherThanPopping() throws {
        Motion.isReduceMotionEnabled = { false }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let source = NSView(frame: NSRect(x: 400, y: 300, width: 24, height: 24))
        window.contentView?.addSubview(source)

        TooltipPresenter.shared.scheduleShow(for: source, label: "New tab", shortcut: "⌘T")
        waitUntil(TooltipPresenter.shared.tooltipForTesting != nil, "the tooltip")
        let tip = try XCTUnwrap(TooltipPresenter.shared.tooltipForTesting)
        let fadeIn = try XCTUnwrap(tip.layer?.animation(forKey: "motion.opacity") as? CABasicAnimation)
        XCTAssertEqual(fadeIn.fromValue as? Float, 0)

        TooltipPresenter.shared.hide(for: source)

        XCTAssertNotNil(tip.superview, "the tooltip leaves by fading, not by vanishing")
        XCTAssertEqual(tip.layer?.opacity, 0)
        waitUntil(tip.superview == nil, "the faded tooltip to unmount")
    }
}
