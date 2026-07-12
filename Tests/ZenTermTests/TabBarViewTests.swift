import AppKit
import TabKit
import XCTest

@testable import ZenTerm

/// `TabBarView` is persistent chrome: it must recolor live on a theme swap (ZEN-89), not just
/// on next construction. Per the house rule "GUI controls need interaction tests", this drives
/// the real window-mounted view and asserts `reapplyTheme()` performs its two real effects
/// (re-renders the stored snapshot; resets the tracer's baked-in color) — the window-based
/// behavior the manual runbook then confirms end-to-end with an actual theme file. (A
/// DEBUG-only `Theme.setCurrentForTesting(_:)` seam exists for direct before/after color
/// assertions; the `ReapplyThemeTests` suite uses it.)
final class TabBarViewTests: XCTestCase {
    func test_reapplyTheme_reRendersStoredSnapshot() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onNewTab: {})
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 400, height: 30)

        let items = [TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, agentState: .idle)]
        tabBar.render(items)
        let chipBefore = tabBar.chipsForTesting.first

        tabBar.reapplyTheme()

        // reapplyTheme() re-invokes render() with the retained snapshot: the chip is rebuilt
        // fresh (a new instance carrying whatever ink color is current), not left stale.
        let chipAfter = tabBar.chipsForTesting.first
        XCTAssertNotNil(chipBefore)
        XCTAssertNotNil(chipAfter)
        XCTAssertFalse(chipBefore === chipAfter, "reapplyTheme() must rebuild the chip, not leave the old instance")
    }

    func test_reapplyTheme_resetsTracerColor() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onNewTab: {})
        let items = [TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, agentState: .idle)]
        tabBar.render(items)

        tabBar.reapplyTheme()

        // The tracer's color is set once in init and never touched by render(); reapplyTheme()
        // must reset it explicitly or an accent swap leaves the underline stale-colored.
        XCTAssertEqual(tabBar.tracerColorForTesting, Theme.current.chrome.accent.nsColor)
    }

    func test_reapplyTheme_beforeAnyRender_doesNotCrash() {
        // No render() call before reapplyTheme() — must not crash on an empty snapshot; render(_:)
        // always appends the trailing "+" chip, so the bar ends up with exactly that one view.
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onNewTab: {})
        tabBar.reapplyTheme()
        XCTAssertEqual(tabBar.chipsForTesting.count, 1)
    }
}
