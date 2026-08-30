import AppKit
import TabKit
import XCTest

@testable import ZenTerm

/// `TabBarView` is persistent chrome: it must recolor live on a theme swap, not just
/// on next construction. Per the house rule "GUI controls need interaction tests", this drives
/// the real window-mounted view and asserts `reapplyTheme()` performs its two real effects
/// (re-renders the stored snapshot; resets the tracer's baked-in color) — the window-based
/// behavior the manual runbook then confirms end-to-end with an actual theme file. (A
/// DEBUG-only `Theme.setCurrentForTesting(_:)` seam exists for direct before/after color
/// assertions; the `ReapplyThemeTests` suite uses it.)
final class TabBarViewTests: WindowTestCase {
    private func mount(_ tabBar: TabBarView) {
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
    }

    private func item(_ id: Int, _ title: String, index: Int, active: Bool = false) -> TabBarItem {
        TabBarItem(id: TabID(id), index: index, title: title, isActive: active, attentionState: .idle)
    }

    /// A re-render keeps each tab's chip. It used to rebuild them all, which took the hovered chip out
    /// of the window mid-hover: its tooltip was torn down and re-armed behind the hover delay, so the
    /// 1.5s title poll read as a blinking tooltip. The chip surviving is what fixes that, and
    /// the label still has to follow the new title.
    func test_render_keepsEachTabsChipAcrossARerender() throws {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([item(1, "one", index: 1, active: true), item(2, "two", index: 2)])
        let before = tabBar.chipsForTesting

        tabBar.render([item(1, "renamed", index: 1, active: true), item(2, "two", index: 2)])

        let after = tabBar.chipsForTesting
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(before[0] === after[0], "the chip for tab 1 is the same view")
        XCTAssertTrue(before[1] === after[1], "and so is tab 2's")
        XCTAssertEqual(
            tabBar.chipLabelsForTesting.first?.string, "1 renamed", "the kept chip shows the new title")
    }

    func test_render_dropsTheChipOfAClosedTab() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([item(1, "one", index: 1, active: true), item(2, "two", index: 2)])
        let closing = tabBar.chipsForTesting[1]

        tabBar.render([item(1, "one", index: 1, active: true)])

        XCTAssertEqual(tabBar.chipsForTesting.count, 1)
        XCTAssertNil(closing.superview, "the closed tab's chip leaves the bar")
    }

    /// Renumbering after a close has to reach the tooltip's keycap, which resolves at hover time from
    /// the chip's own index rather than one captured when it was built.
    func test_render_renumbersAKeptChipsShortcut() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([item(1, "one", index: 1, active: true), item(2, "two", index: 2)])
        XCTAssertEqual(tabBar.chipTooltipsForTesting[1].shortcut, CommandCatalog.spec(for: .selectTab(2)).shortcut)

        tabBar.render([item(2, "two", index: 1, active: true)])  // tab 1 closed, tab 2 becomes tab 1

        XCTAssertEqual(
            tabBar.chipTooltipsForTesting[0].shortcut, CommandCatalog.spec(for: .selectTab(1)).shortcut,
            "the kept chip's tooltip names its new number")
    }

    /// The chip persists now, so a theme swap has to recolor the label it already has. This is what the
    /// old "reapplyTheme rebuilds the chip" assertion was really protecting.
    func test_reapplyTheme_recolorsTheKeptChipsLabel() throws {
        let original = Theme.current
        defer { Theme.setCurrentForTesting(original) }
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([item(1, "one", index: 1, active: true)])
        let chip = try XCTUnwrap(tabBar.chipsForTesting.first)
        let inkBefore = try XCTUnwrap(labelInk(tabBar))

        Theme.setCurrentForTesting(try makeAlternateTheme())
        tabBar.reapplyTheme()

        XCTAssertTrue(chip === tabBar.chipsForTesting.first, "the chip is recolored in place, not replaced")
        XCTAssertNotEqual(labelInk(tabBar), inkBefore, "the label picked up the new theme's ink")
    }

    /// The title run's foreground color — the second attribute run, after the number prefix.
    private func labelInk(_ tabBar: TabBarView) -> NSColor? {
        guard let label = tabBar.chipLabelsForTesting.first, label.length > 2 else { return nil }
        return label.attribute(.foregroundColor, at: label.length - 1, effectiveRange: nil) as? NSColor
    }

    /// A theme with a clearly different foreground, built through the real loader so `chrome`'s derived
    /// roles are populated the way a genuine swap produces them (as `ReapplyThemeTests` does).
    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-tabbar-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        themeRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 5=#00ff00
        # The accent slot, named from the constant rather than pinned: this fixture used to
        # move palette 5 because that was the accent, and went blind when the default moved.
        palette = \(AccentSlot.themeDefault.ansiIndex)=#00ffff
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private var themeRoots: [URL] = []

    override func tearDownWithError() throws {
        for dir in themeRoots { try? FileManager.default.removeItem(at: dir) }
        themeRoots = []
        try super.tearDownWithError()
    }

    func test_reapplyTheme_resetsTracerColor() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        let items = [TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, attentionState: .idle)]
        tabBar.render(items)

        tabBar.reapplyTheme()

        // The tracer's color is set once in init and never touched by render(); reapplyTheme()
        // must reset it explicitly or an accent swap leaves the underline stale-colored.
        XCTAssertEqual(tabBar.tracerColorForTesting, Theme.current.chrome.accent.nsColor)
    }

    func test_reapplyTheme_beforeAnyRender_doesNotCrash() {
        // No render() call before reapplyTheme() — must not crash on an empty snapshot; with no
        // tabs rendered the bar holds no chips (new-tab lives in the footer dock now).
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        tabBar.reapplyTheme()
        XCTAssertTrue(tabBar.chipsForTesting.isEmpty)
    }

    func test_tabLabel_isBareNumberWithNoCommandGlyph() {
        // The inline label is a bare number for every tab now — the ⌘N shortcut moved to the
        // hover tooltip, so the glyph never sits inline.
        let one = TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, attentionState: .idle)
        let nine = TabBarItem(id: TabID(9), index: 9, title: "nine", isActive: false, attentionState: .idle)
        let ten = TabBarItem(id: TabID(10), index: 10, title: "ten", isActive: false, attentionState: .idle)
        XCTAssertTrue(TabBarView.tabLabelStringForTesting(one).hasPrefix("1 "))
        XCTAssertTrue(TabBarView.tabLabelStringForTesting(nine).hasPrefix("9 "))
        XCTAssertTrue(TabBarView.tabLabelStringForTesting(ten).hasPrefix("10 "))
        for item in [one, nine, ten] {
            XCTAssertFalse(TabBarView.tabLabelStringForTesting(item).contains("⌘"))
        }
    }

    func test_chipTooltip_readsFocusTabWithCommandShortcut() {
        // The tooltip reads "Focus tab" (not the tab's name); tabs 1–9 resolve a ⌘N keycap from
        // the live keymap, 10+ have no binding so no keycap.
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        tabBar.render([
            TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, attentionState: .idle),
            TabBarItem(id: TabID(10), index: 10, title: "ten", isActive: false, attentionState: .idle),
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
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 160, height: 30)

        let many = (1...14).map {
            TabBarItem(id: TabID($0), index: $0, title: "tab\($0)", isActive: $0 == 1, attentionState: .idle)
        }
        tabBar.render(many)
        tabBar.layoutSubtreeIfNeeded()
        XCTAssertTrue(tabBar.isOverflowFadedForTesting, "many tabs in a narrow bar must fade the trailing edge")
    }

    func test_overflow_noFadeWhenTabsFit() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 800, height: 30)

        tabBar.render([TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, attentionState: .idle)])
        tabBar.layoutSubtreeIfNeeded()
        XCTAssertFalse(tabBar.isOverflowFadedForTesting, "a single tab in a wide bar must not fade")
    }

    func test_overflow_leadingFadesOnceScrolledRight() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 160, height: 30)

        let many = (1...14).map {
            TabBarItem(id: TabID($0), index: $0, title: "tab\($0)", isActive: $0 == 1, attentionState: .idle)
        }
        tabBar.render(many)
        tabBar.layoutSubtreeIfNeeded()
        XCTAssertFalse(tabBar.isLeadingFadedForTesting, "at the start there's nothing off the left edge")

        tabBar.scrollToForTesting(x: 80)  // drag the strip rightward
        XCTAssertTrue(tabBar.isLeadingFadedForTesting, "scrolling tabs off the left must fade that edge")
    }

    // MARK: - resting weight

    /// The number and the title are one label and must read as one: same color per state, full
    /// bright on the active tab and resting on the others. Read off the rendered runs rather than the
    /// constants, so a test cannot restate the values and pass against its own copy of them.
    @MainActor
    func test_theNumberAndTitle_shareOneColorPerState() throws {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([item(1, "active", index: 1, active: true), item(2, "idle", index: 2)])
        let labels = tabBar.chipLabelsForTesting
        XCTAssertEqual(labels.count, 2)

        for (position, label) in labels.enumerated() {
            let numberColor = try XCTUnwrap(
                label.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            let titleColor = try XCTUnwrap(
                label.attribute(.foregroundColor, at: label.length - 1, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(
                numberColor, titleColor,
                "chip \(position): the number and the title are one label, at one weight")
        }

        let activeColor = try XCTUnwrap(
            labels[0].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let idleColor = try XCTUnwrap(
            labels[1].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(activeColor, TabBarView.activeInkForTesting)
        XCTAssertEqual(idleColor, TabBarView.idleInkForTesting)
        XCTAssertGreaterThan(
            activeColor.alphaComponent, idleColor.alphaComponent, "the active tab still stands out")
    }

    /// The attention states still speak through the number alone: that is a signal about the tab, not
    /// a weight, so it survives the two halves sharing one ink.
    @MainActor
    func test_aWaitingTab_stillMarksItsNumberWithTheAttentionColor() throws {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([
            TabBarItem(id: TabID(1), index: 1, title: "waiting", isActive: false, attentionState: .waiting)
        ])
        let label = try XCTUnwrap(tabBar.chipLabelsForTesting.first)
        let numberColor = try XCTUnwrap(
            label.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let titleColor = try XCTUnwrap(
            label.attribute(.foregroundColor, at: label.length - 1, effectiveRange: nil) as? NSColor)

        XCTAssertEqual(numberColor, Theme.current.chrome.attention.nsColor)
        XCTAssertEqual(titleColor, TabBarView.idleInkForTesting)
    }

    // MARK: rename

    /// A keyed window: the chip's click path only matters with a window that can take focus.
    private func mountKeyed(_ tabBar: TabBarView) -> NSWindow {
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
        window.makeKeyAndOrderFront(nil)
        tabBar.layoutSubtreeIfNeeded()
        return window
    }

    private func click(_ view: NSView, count: Int) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: count, pressure: 1))
        view.mouseDown(with: event)
    }

    /// The bar asks; the window opens the card. Renaming is not the bar's job, so all it owes is
    /// the right tab id off a double-click.
    func test_doubleClickingAChip_asksToRenameThatTab() throws {
        var renamed: [TabID] = []
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { renamed.append($0) })
        _ = mountKeyed(tabBar)
        tabBar.render([item(1, "zen-term", index: 1, active: true), item(2, "api", index: 2)])

        try click(tabBar.chipsForTesting[1], count: 2)

        XCTAssertEqual(renamed, [TabID(2)], "the chip that was double-clicked, not the active tab")
    }

    /// A single click must still just select, or a rename card would open on every tab switch.
    func test_singleClickingAChip_selectsAndAsksForNoRename() throws {
        var selected: [TabID] = []
        var renamed: [TabID] = []
        let tabBar = TabBarView(
            onSelect: { selected.append($0) }, onClose: { _ in }, onRename: { renamed.append($0) })
        _ = mountKeyed(tabBar)
        tabBar.render([item(1, "zen-term", index: 1, active: true), item(2, "api", index: 2)])

        try click(tabBar.chipsForTesting[1], count: 1)

        XCTAssertEqual(selected, [TabID(2)])
        XCTAssertTrue(renamed.isEmpty)
    }
}
