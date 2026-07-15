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
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in })
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
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in })
        let items = [TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, agentState: .idle)]
        tabBar.render(items)

        tabBar.reapplyTheme()

        // The tracer's color is set once in init and never touched by render(); reapplyTheme()
        // must reset it explicitly or an accent swap leaves the underline stale-colored.
        XCTAssertEqual(tabBar.tracerColorForTesting, Theme.current.chrome.accent.nsColor)
    }

    func test_reapplyTheme_beforeAnyRender_doesNotCrash() {
        // No render() call before reapplyTheme() — must not crash on an empty snapshot; with no
        // tabs rendered the bar holds no chips (new-tab lives in the footer dock now).
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in })
        tabBar.reapplyTheme()
        XCTAssertTrue(tabBar.chipsForTesting.isEmpty)
    }

    func test_tabLabel_isBareNumberWithNoCommandGlyph() {
        // The inline label is a bare number for every tab now — the ⌘N shortcut moved to the
        // hover tooltip, so the glyph never sits inline (ZEN-110).
        let one = TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, agentState: .idle)
        let nine = TabBarItem(id: TabID(9), index: 9, title: "nine", isActive: false, agentState: .idle)
        let ten = TabBarItem(id: TabID(10), index: 10, title: "ten", isActive: false, agentState: .idle)
        XCTAssertTrue(TabBarView.tabLabelStringForTesting(one).hasPrefix("1 "))
        XCTAssertTrue(TabBarView.tabLabelStringForTesting(nine).hasPrefix("9 "))
        XCTAssertTrue(TabBarView.tabLabelStringForTesting(ten).hasPrefix("10 "))
        for item in [one, nine, ten] {
            XCTAssertFalse(TabBarView.tabLabelStringForTesting(item).contains("⌘"))
        }
    }

    func test_chipTooltip_readsFocusTabWithCommandShortcut() {
        // The tooltip reads "Focus tab" (not the tab's name); tabs 1–9 resolve a ⌘N keycap from
        // the live keymap, 10+ have no binding so no keycap (ZEN-110).
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in })
        tabBar.render([
            TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, agentState: .idle),
            TabBarItem(id: TabID(10), index: 10, title: "ten", isActive: false, agentState: .idle),
        ])
        let tooltips = tabBar.chipTooltipsForTesting
        XCTAssertEqual(tooltips.count, 2)
        XCTAssertEqual(tooltips[0].label, "Focus tab")
        // ⌘1, resolved from the live keymap rather than hard-coded.
        XCTAssertEqual(tooltips[0].shortcut, CommandCatalog.spec(for: .selectTab(1)).shortcut)
        XCTAssertEqual(tooltips[1].label, "Focus tab")
        XCTAssertNil(tooltips[1].shortcut)
    }

    func test_overflow_fadesWhenTabsExceedWidth() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in })
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 160, height: 30)

        let many = (1...14).map {
            TabBarItem(id: TabID($0), index: $0, title: "tab\($0)", isActive: $0 == 1, agentState: .idle)
        }
        tabBar.render(many)
        tabBar.layoutSubtreeIfNeeded()
        XCTAssertTrue(tabBar.isOverflowFadedForTesting, "many tabs in a narrow bar must fade the trailing edge")
    }

    func test_overflow_noFadeWhenTabsFit() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in })
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 800, height: 30)

        tabBar.render([TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, agentState: .idle)])
        tabBar.layoutSubtreeIfNeeded()
        XCTAssertFalse(tabBar.isOverflowFadedForTesting, "a single tab in a wide bar must not fade")
    }

    func test_overflow_leadingFadesOnceScrolledRight() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in })
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 160, height: 30)

        let many = (1...14).map {
            TabBarItem(id: TabID($0), index: $0, title: "tab\($0)", isActive: $0 == 1, agentState: .idle)
        }
        tabBar.render(many)
        tabBar.layoutSubtreeIfNeeded()
        XCTAssertFalse(tabBar.isLeadingFadedForTesting, "at the start there's nothing off the left edge")

        tabBar.scrollToForTesting(x: 80)  // drag the strip rightward
        XCTAssertTrue(tabBar.isLeadingFadedForTesting, "scrolling tabs off the left must fade that edge")
    }
}
