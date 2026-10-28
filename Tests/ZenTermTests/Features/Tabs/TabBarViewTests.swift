import AppKit
import TabKit
import XCTest

@testable import ZenTerm

final class TabBarViewTests: WindowTestCase {
    private func mount(_ tabBar: TabBarView) {
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tabBar)
        tabBar.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func item(_ id: Int, _ title: String, index: Int, active: Bool = false) -> TabBarItem {
        TabBarItem(id: TabID(id), index: index, title: title, isActive: active, attentionState: .idle)
    }

    func test_hoveringAChip_layingOutItsCloseButton_conflictsWithNoConstraint() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)

        let conflicts = constraintConflicts {
            tabBar.render([item(1, "one", index: 1, active: true), item(2, "two", index: 2)])
            tabBar.layoutSubtreeIfNeeded()
            for chip in tabBar.chipsForTesting {
                chip.setHover(true)
                chip.layoutSubtreeIfNeeded()
            }
        }

        XCTAssertEqual(conflicts, [])
    }

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
            tabBar.chipLabelsForTesting.first?.string, "renamed", "the kept chip shows the new title")
    }

    func test_render_capsAChipsWidthAndTruncatesTheTitle() throws {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        let long = "ZenTerm \u{2387} feature/zen-455-worktree-rows-in-the-picker-and-then-some"

        tabBar.render([item(1, "one", index: 1, active: true), item(2, long, index: 2)])

        tabBar.layoutSubtreeIfNeeded()
        let widths = tabBar.chipsForTesting.map(\.frame.width)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(widths.last), TabChip.maxChipWidth, "the chip stops at the cap")
        XCTAssertGreaterThan(
            try XCTUnwrap(widths.last), try XCTUnwrap(widths.first),
            "a long title still takes more room than a short one, up to the cap")

        let chip = try XCTUnwrap(tabBar.chipsForTesting.last)
        let label = try XCTUnwrap(
            descendants(of: chip).compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.maximumNumberOfLines, 1)
        let style =
            label.attributedStringValue.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.lineBreakMode, .byTruncatingTail, "truncate, never wrap")
        XCTAssertLessThanOrEqual(
            label.frame.height, chip.frame.height, "one line, inside the chip")
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

    func test_render_renumbersAKeptChipsShortcut() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([item(1, "one", index: 1, active: true), item(2, "two", index: 2)])
        XCTAssertEqual(tabBar.chipTooltipsForTesting[1].shortcut, CommandCatalog.spec(for: .selectTab(2)).shortcut)

        tabBar.render([item(2, "two", index: 1, active: true)])

        XCTAssertEqual(
            tabBar.chipTooltipsForTesting[0].shortcut, CommandCatalog.spec(for: .selectTab(1)).shortcut,
            "the kept chip's tooltip names its new number")
    }

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

    private func labelInk(_ tabBar: TabBarView) -> NSColor? {
        guard let label = tabBar.chipLabelsForTesting.first, label.length > 2 else { return nil }
        return label.attribute(.foregroundColor, at: label.length - 1, effectiveRange: nil) as? NSColor
    }

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

    func test_reapplyTheme_resetsPillColor() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        let items = [TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, attentionState: .idle)]
        tabBar.render(items)

        tabBar.reapplyTheme()

        XCTAssertEqual(tabBar.pillColorForTesting, Theme.current.chrome.fill(.active))
    }

    func test_reapplyTheme_beforeAnyRender_doesNotCrash() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        tabBar.reapplyTheme()
        XCTAssertTrue(tabBar.chipsForTesting.isEmpty)
    }

    func test_chipLabel_isTheTitleAlone() {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([item(1, "one", index: 1, active: true), item(10, "ten", index: 10)])

        XCTAssertEqual(tabBar.chipLabelsForTesting.map(\.string), ["one", "ten"], "no number, no command glyph")
    }

    func test_chipTooltip_namesThatTabsDirectoryWithCommandShortcut() {
        let home = PathDisplay.homePath
        let dirs = [TabID(1): URL(fileURLWithPath: home + "/Dev/one"), TabID(10): URL(fileURLWithPath: "/tmp/ten")]
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in }, directory: { dirs[$0] })
        tabBar.render([
            TabBarItem(id: TabID(1), index: 1, title: "one", isActive: true, attentionState: .idle),
            TabBarItem(id: TabID(10), index: 10, title: "ten", isActive: false, attentionState: .idle),
        ])
        let tooltips = tabBar.chipTooltipsForTesting
        XCTAssertEqual(tooltips.count, 2)
        XCTAssertEqual(tooltips[0].label, "~/Dev/one")
        XCTAssertEqual(tooltips[0].shortcut, CommandCatalog.spec(for: .selectTab(1)).shortcut)
        XCTAssertEqual(tooltips[1].label, "/tmp/ten")
        XCTAssertNil(tooltips[1].shortcut)
    }

    func test_hoveringAChip_showsItsDirectoryAsItIsNow() throws {
        var dir = URL(fileURLWithPath: "/tmp/before")
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in }, directory: { _ in dir })
        mount(tabBar)
        tabBar.render([item(1, "one", index: 1, active: true)])
        let chip = try XCTUnwrap(tabBar.chipsForTesting.first)
        defer { TooltipPresenter.shared.dismiss() }

        try hover(chip)
        XCTAssertEqual(try presentedTooltip().labelForTesting, "/tmp/before")

        try unhover(chip)
        dir = URL(fileURLWithPath: "/tmp/after")
        try hover(chip)
        XCTAssertEqual(try presentedTooltip().labelForTesting, "/tmp/after", "a cd after the chip was built shows")
    }

    func test_hoveringAChip_withNoKnownDirectory_showsNoTooltip() throws {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        tabBar.render([item(1, "one", index: 1, active: true)])
        TooltipPresenter.shared.dismiss()

        try hover(try XCTUnwrap(tabBar.chipsForTesting.first))
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        XCTAssertNil(TooltipPresenter.shared.tooltipForTesting)
    }

    private func mouseEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func hover(_ chip: NSView) throws {
        TooltipPresenter.shared.dismiss()
        chip.mouseEntered(with: try mouseEvent())
    }

    private func unhover(_ chip: NSView) throws {
        chip.mouseExited(with: try mouseEvent())
    }

    private func presentedTooltip() throws -> ChromeTooltip {
        let deadline = Date().addingTimeInterval(2)
        while TooltipPresenter.shared.tooltipForTesting == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return try XCTUnwrap(TooltipPresenter.shared.tooltipForTesting, "no tooltip appeared on hover")
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

        tabBar.scrollToForTesting(x: 80)
        XCTAssertTrue(tabBar.isLeadingFadedForTesting, "scrolling tabs off the left must fade that edge")
    }

    private func labelColor(_ chip: TabChip) throws -> NSColor {
        let label = chip.attributedLabelForTesting
        return try XCTUnwrap(label.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    }

    @MainActor
    func test_theTitleInk_isSubtleAtRest_andNormalWhenCurrentOrHovered() throws {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        _ = mountKeyed(tabBar)
        tabBar.render([item(1, "active", index: 1, active: true), item(2, "idle", index: 2)])
        let chrome = Theme.current.chrome
        let chips = tabBar.chipsForTesting

        XCTAssertEqual(try labelColor(chips[0]), chrome.ink(.normal))
        XCTAssertEqual(try labelColor(chips[1]), chrome.ink(.subtle))

        chips[1].setHover(true)
        XCTAssertEqual(try labelColor(chips[1]), chrome.ink(.normal), "hover restyles the title")
        chips[1].setHover(false)
        XCTAssertEqual(try labelColor(chips[1]), chrome.ink(.subtle))
    }

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

    func test_doubleClickingAChip_asksToRenameThatTab() throws {
        var renamed: [TabID] = []
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { renamed.append($0) })
        _ = mountKeyed(tabBar)
        tabBar.render([item(1, "zen-term", index: 1, active: true), item(2, "api", index: 2)])

        try click(tabBar.chipsForTesting[1], count: 1)
        try click(tabBar.chipsForTesting[1], count: 2)

        XCTAssertEqual(renamed, [TabID(2)], "the chip that was double-clicked, not the active tab")
    }

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

    func test_movingTheActiveTabScrollsItBackIntoView() throws {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        let names = (1...14).map { "tab-number-\($0)" }
        func snapshot(active: Int) -> [TabBarItem] {
            names.enumerated().map { i, name in
                item(i + 1, name, index: i + 1, active: i + 1 == active)
            }
        }
        tabBar.render(snapshot(active: 1))
        tabBar.layoutSubtreeIfNeeded()

        var moved = names
        let carried = moved.removeFirst()
        moved.append(carried)
        let items = moved.enumerated().map { i, name in
            item(names.firstIndex(of: name)! + 1, name, index: i + 1, active: name == carried)
        }
        tabBar.render(items)
        tabBar.layoutSubtreeIfNeeded()

        let chip = try XCTUnwrap(tabBar.chipsForTesting.last)
        XCTAssertTrue(
            tabBar.visibleStripRectForTesting.intersects(chip.frame),
            "the moved tab has to be scrolled back into view, not left off the end of the strip")
    }

    func test_aTitleChangeDoesNotYankTheStripBack() throws {
        let tabBar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
        mount(tabBar)
        let names = (1...14).map { "tab-number-\($0)" }
        func snapshot(firstTitle: String) -> [TabBarItem] {
            names.enumerated().map { i, name in
                item(i + 1, i == 0 ? firstTitle : name, index: i + 1, active: i == 0)
            }
        }
        tabBar.render(snapshot(firstTitle: names[0]))
        tabBar.layoutSubtreeIfNeeded()
        tabBar.scrollToForTesting(x: 300)
        let scrolled = tabBar.visibleStripRectForTesting.origin.x
        XCTAssertGreaterThan(scrolled, 0, "the strip is scrolled away from tab 1")

        tabBar.render(snapshot(firstTitle: "a-new-title-from-the-poll"))
        tabBar.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            tabBar.visibleStripRectForTesting.origin.x, scrolled, accuracy: 0.5,
            "a title poll must leave the scroll position alone")
    }

    private func windowEvent(
        _ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint, clicks: Int = 1, at time: TimeInterval = 0
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                pressure: 1))
    }

    private func windowPoint(_ view: NSView) -> CGPoint {
        view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    private var pressed: NSView?

    private func down(_ window: NSWindow, at point: CGPoint, clicks: Int = 1, time: TimeInterval = 0) throws {
        let target = window.contentView?.superview?.hitTest(point)
        pressed = target
        target?.mouseDown(with: try windowEvent(.leftMouseDown, in: window, at: point, clicks: clicks, at: time))
    }

    private func up(_ window: NSWindow, at point: CGPoint, clicks: Int = 1, time: TimeInterval = 0) throws {
        pressed?.mouseUp(with: try windowEvent(.leftMouseUp, in: window, at: point, clicks: clicks, at: time))
        pressed = nil
    }

    private func press(
        _ window: NSWindow, at point: CGPoint, release releasePoint: CGPoint? = nil, clicks: Int = 1,
        time: TimeInterval = 0
    ) throws {
        try down(window, at: point, clicks: clicks, time: time)
        try up(window, at: releasePoint ?? point, clicks: clicks, time: time)
    }

    private func settledBar(
        _ items: [TabBarItem], onSelect: @escaping (TabID) -> Void = { _ in },
        onClose: @escaping (TabID) -> Void = { _ in }, onRename: @escaping (TabID) -> Void = { _ in }
    ) -> (bar: TabBarView, window: NSWindow) {
        let bar = TabBarView(onSelect: onSelect, onClose: onClose, onRename: onRename)
        let window = mountKeyed(bar)
        bar.render(items)
        bar.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    func test_theCloseButton_closesOnMouseUp_andNotOnPress() throws {
        var closed: [TabID] = []
        var selected: [TabID] = []
        let (bar, window) = settledBar(
            [item(1, "one", index: 1, active: true), item(2, "two", index: 2)],
            onSelect: { selected.append($0) }, onClose: { closed.append($0) })
        let chip = bar.chipsForTesting[1]
        try hover(chip)
        bar.layoutSubtreeIfNeeded()
        let target = windowPoint(chip.closeButtonForTesting)

        try down(window, at: target)
        XCTAssertTrue(closed.isEmpty, "a press alone closes nothing")
        try up(window, at: target)

        XCTAssertEqual(closed, [TabID(2)])
        XCTAssertTrue(selected.isEmpty, "the x never selects the tab it closes")
    }

    func test_aPressOnTheCloseButtonDraggedOut_closesNothing_andReordersNothing() throws {
        var closed: [TabID] = []
        let (bar, window) = settledBar(
            [item(1, "one", index: 1, active: true), item(2, "two", index: 2)], onClose: { closed.append($0) })
        let chip = bar.chipsForTesting[1]
        try hover(chip)
        bar.layoutSubtreeIfNeeded()
        let before = bar.chipsForTesting.map(\.frame)

        try press(window, at: windowPoint(chip.closeButtonForTesting), release: CGPoint(x: 390, y: 40))

        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(bar.chipsForTesting.map(\.frame), before)
    }

    func test_doubleClickingTheCloseButton_closesOneTab_andRenamesNone() throws {
        var items = [
            item(1, "one", index: 1, active: true), item(2, "two", index: 2), item(3, "three", index: 3),
        ]
        var closed: [TabID] = []
        var renamed: [TabID] = []
        var barRef: TabBarView?
        let (bar, window) = settledBar(
            items,
            onClose: { id in
                closed.append(id)
                items.removeAll { $0.id == id }
                barRef?.render(items)
                barRef?.layoutSubtreeIfNeeded()
            },
            onRename: { renamed.append($0) })
        barRef = bar
        try press(window, at: windowPoint(bar.chipsForTesting[2]), clicks: 1, time: 1)
        let chip = bar.chipsForTesting[1]
        try hover(chip)
        bar.layoutSubtreeIfNeeded()
        let target = windowPoint(chip.closeButtonForTesting)

        try press(window, at: target, clicks: 1, time: 10)
        try press(window, at: target, clicks: 2, time: 10.2)

        XCTAssertEqual(closed, [TabID(2)], "one tab closes, not the one that slid under the pointer")
        XCTAssertTrue(renamed.isEmpty, "and the second click of the pair renames nothing")
    }

    func test_theCloseButton_isAbsentAtRest_soTheSlotClicksThroughToTheChip() throws {
        var closed: [TabID] = []
        var selected: [TabID] = []
        let (bar, window) = settledBar(
            [item(1, "one", index: 1, active: true), item(2, "two", index: 2)],
            onSelect: { selected.append($0) }, onClose: { closed.append($0) })
        let chip = bar.chipsForTesting[1]
        let slotCenter = CGPoint(x: chip.closeFrameForTesting.midX, y: chip.closeFrameForTesting.midY)

        XCTAssertFalse(chip.isCloseVisibleForTesting)
        XCTAssertTrue(chip.hitTest(chip.convert(slotCenter, to: chip.superview)) === chip)

        try press(window, at: chip.convert(slotCenter, to: nil))

        XCTAssertEqual(selected, [TabID(2)])
        XCTAssertTrue(closed.isEmpty)
    }

    func test_hover_neverChangesAnyChipWidthOrAnyNeighborsPosition() throws {
        let states: [TabAttentionState] = [.idle, .completed, .waiting]
        for state in states {
            for currentIndex in [1, 2] {
                let items = (1...3).map {
                    TabBarItem(
                        id: TabID($0), index: $0, title: "tab \($0)", isActive: $0 == currentIndex,
                        attentionState: state)
                }
                let (bar, _) = settledBar(items)
                let before = bar.chipsForTesting.map(\.frame)

                for chip in bar.chipsForTesting {
                    let widthAtRest = chip.fittingWidth
                    bar.forceHoverForGallery(tab: chip.id)
                    XCTAssertTrue(chip.isHoveredForTesting)
                    bar.render(items)
                    bar.layoutSubtreeIfNeeded()
                    XCTAssertEqual(
                        chip.fittingWidth, widthAtRest, "\(state), current \(currentIndex): hover resized a chip")
                    XCTAssertEqual(
                        bar.chipsForTesting.map(\.frame), before,
                        "\(state), current \(currentIndex): hover moved a chip")
                }
            }
        }
    }

    @MainActor
    func test_theDot_followsAttention_andHoverSwapsItForTheCloseButtonInTheSameSlot() throws {
        let chrome = Theme.current.chrome
        let (bar, _) = settledBar([
            TabBarItem(id: TabID(1), index: 1, title: "idle", isActive: true, attentionState: .idle),
            TabBarItem(
                id: TabID(2), index: 2, title: "working", isActive: false,
                attentionState: SurfaceAttention.working.tabState),
            TabBarItem(id: TabID(3), index: 3, title: "done", isActive: false, attentionState: .completed),
            TabBarItem(id: TabID(4), index: 4, title: "asks", isActive: false, attentionState: .waiting),
        ])
        let chips = bar.chipsForTesting

        XCTAssertEqual(chips.map(\.isDotVisibleForTesting), [false, false, true, true], "idle and working show none")
        XCTAssertEqual(chips[2].dotColorForTesting, chrome.positive.nsColor)
        XCTAssertEqual(chips[3].dotColorForTesting, chrome.attention.nsColor)

        let dotCenter = CGPoint(x: chips[3].dotFrameForTesting.midX, y: chips[3].dotFrameForTesting.midY)
        try hover(chips[3])
        bar.layoutSubtreeIfNeeded()

        XCTAssertFalse(chips[3].isDotVisibleForTesting, "the x replaces the dot")
        XCTAssertTrue(chips[3].isCloseVisibleForTesting)
        let slot = chips[3].closeFrameForTesting
        XCTAssertEqual(slot.size, CGSize(width: ChromeMetrics.Height.xs, height: ChromeMetrics.Height.xs))
        XCTAssertEqual(chips[3].bounds.width - slot.maxX, ChromeMetrics.Spacing.s2, "inset from the trailing edge")
        XCTAssertEqual(slot.midY, chips[3].bounds.midY, accuracy: 0.01, "centered in the chip")
        XCTAssertEqual(chips[3].closeFrameForTesting.midX, dotCenter.x, accuracy: 0.01)
        XCTAssertEqual(chips[3].closeFrameForTesting.midY, dotCenter.y, accuracy: 0.01)
    }

    func test_theLabelFades_onlyWhileTheCloseButtonShows() throws {
        let (bar, _) = settledBar([item(1, "one", index: 1, active: true), item(2, "two", index: 2)])
        let chip = bar.chipsForTesting[1]
        XCTAssertFalse(chip.isLabelFadedForTesting)

        try hover(chip)
        XCTAssertTrue(chip.isLabelFadedForTesting)

        try unhover(chip)
        XCTAssertFalse(chip.isLabelFadedForTesting)
    }

    func test_aShortTitle_stillGetsTheMinimumWidth() {
        let (bar, _) = settledBar([item(1, "a", index: 1, active: true)])
        XCTAssertEqual(bar.chipsForTesting[0].frame.width, TabChip.minWidth)
    }

    func test_thePill_sitsOnTheCurrentChip_afterASelectAndAfterAReorder() throws {
        let (bar, _) = settledBar([
            item(1, "one", index: 1, active: true), item(2, "two-is-longer", index: 2), item(3, "three", index: 3),
        ])
        XCTAssertEqual(bar.pillFrameForTesting, bar.chipsForTesting[0].frame)
        XCTAssertEqual(bar.pillColorForTesting, Theme.current.chrome.fill(.active))

        bar.render([
            item(1, "one", index: 1), item(2, "two-is-longer", index: 2, active: true), item(3, "three", index: 3),
        ])
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.pillFrameForTesting, bar.chipsForTesting[1].frame, "after select")

        bar.render([
            item(3, "three", index: 1), item(2, "two-is-longer", index: 2, active: true), item(1, "one", index: 3),
        ])
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.pillFrameForTesting, bar.chipsForTesting[1].frame, "after a reorder that keeps the slot")

        bar.render([
            item(2, "two-is-longer", index: 1, active: true), item(3, "three", index: 2), item(1, "one", index: 3),
        ])
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.pillFrameForTesting, bar.chipsForTesting[0].frame, "after the current tab moves")
    }

    func test_thePillsSlide_survivesARerenderThatKeepsTheSelection() {
        let saved = Motion.isReduceMotionEnabled
        Motion.isReduceMotionEnabled = { false }
        defer { Motion.isReduceMotionEnabled = saved }
        let (bar, _) = settledBar([item(1, "one", index: 1, active: true), item(2, "two", index: 2)])
        let switched = [item(1, "one", index: 1), item(2, "two", index: 2, active: true)]

        bar.render(switched)
        XCTAssertTrue(bar.isPillSlidingForTesting, "a selection change slides the pill")

        bar.render(switched)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.isPillSlidingForTesting, "a rerender that leaves the pill in place keeps the slide")
    }

    func test_aMiddleClick_closesTheTab_includingOverItsCloseButton() throws {
        var closed: [TabID] = []
        let (bar, window) = settledBar(
            [item(1, "one", index: 1, active: true), item(2, "two", index: 2)], onClose: { closed.append($0) })
        let chip = bar.chipsForTesting[1]
        try hover(chip)
        bar.layoutSubtreeIfNeeded()
        let middle = try middleMouseDown(in: window)

        let overLabel = try XCTUnwrap(
            window.contentView?.superview?.hitTest(
                chip.convert(CGPoint(x: chip.labelFrameForTesting.midX, y: chip.labelFrameForTesting.midY), to: nil)))
        overLabel.otherMouseDown(with: middle)
        let overClose = try XCTUnwrap(
            window.contentView?.superview?.hitTest(windowPoint(chip.closeButtonForTesting)))
        XCTAssertTrue(overClose.isDescendant(of: chip.closeButtonForTesting), "the x is what the pointer is over")
        overClose.otherMouseDown(with: middle)

        XCTAssertEqual(closed, [TabID(2), TabID(2)])
    }

    func test_onlyTheMiddleButtonCloses() {
        XCTAssertTrue(TerminalTabChip.closesOn(mouseButton: 2))
        XCTAssertFalse(TerminalTabChip.closesOn(mouseButton: 0))
        XCTAssertFalse(TerminalTabChip.closesOn(mouseButton: 1))
        XCTAssertFalse(TerminalTabChip.closesOn(mouseButton: 3))
    }

    private func middleMouseDown(in window: NSWindow) throws -> NSEvent {
        let cg = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                mouseButton: .center))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.buttonNumber, 2, "the event is a real middle press")
        return event
    }

    func test_everyTitle_showsWhole_withOrWithoutADot() {
        let (bar, _) = settledBar([
            TabBarItem(id: TabID(1), index: 1, title: "shell", isActive: true, attentionState: .idle),
            TabBarItem(id: TabID(2), index: 2, title: "shell", isActive: false, attentionState: .waiting),
            TabBarItem(id: TabID(3), index: 3, title: "~/Dev/zen-term", isActive: false, attentionState: .completed),
        ])
        XCTAssertEqual(bar.chipsForTesting.map(\.isTitleTruncatedForTesting), [false, false, false])
    }
}
