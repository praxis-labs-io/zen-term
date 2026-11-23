import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class DropdownTests: WindowTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { true }
    }

    func test_selectedIndex_reflectsInitAndSetItems() {
        let items = [
            DropdownItem(title: "A", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "B", group: "G", note: "dark", isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        XCTAssertEqual(dropdown.selectedIndex, 0)

        dropdown.setItems(items, selectedIndex: 1)
        XCTAssertEqual(dropdown.selectedIndex, 1)
    }

    func test_titleShowsSelectedItem() {
        let items = [
            DropdownItem(title: "Rosé Pine Moon", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "Nord", group: "Bundled", note: "dark", isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 1) { _ in }
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Nord")
    }

    func test_openList_producesVisibleCard() {
        let items = [
            DropdownItem(title: "Rosé Pine Moon", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "Nord", group: "Bundled", note: "Dark", isSelected: false),
            DropdownItem(title: "Catppuccin Mocha", group: "Bundled", note: "Dark", isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: ChromeMetrics.Height.control)

        dropdown.openListForTesting()

        XCTAssertTrue(dropdown.isPopoverOpen)
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.height, 0)
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.width, 0)
    }

    func test_escKeyDown_closesOpenList() {
        let items = [
            DropdownItem(title: "A", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "B", group: nil, note: nil, isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: ChromeMetrics.Height.control)
        window.makeFirstResponder(dropdown)
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen)

        NSApp.sendEvent(Self.escape(in: window))

        XCTAssertFalse(dropdown.isPopoverOpen, "Esc closes the list")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView }, "the card left the window")
    }

    func test_removingHostFromWindow_closesOpenList() {
        let items = [
            DropdownItem(title: "A", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "B", group: nil, note: nil, isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(host)
        host.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: ChromeMetrics.Height.control)
        window.makeFirstResponder(dropdown)
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen)
        XCTAssertTrue(window.contentView!.subviews.contains { $0 is ShadowCardView })

        host.removeFromSuperview()

        XCTAssertFalse(dropdown.isPopoverOpen, "list closes when the dropdown leaves the window")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView },
            "no orphaned list card left drawn on the content view")
    }

    private func filterFixture(selectedIndex: Int = 0, onChange: @escaping (Int) -> Void = { _ in }) -> Dropdown {
        let titles = ["Gruvbox Dark", "Gruvbox Light", "Nord", "Rosé Pine", "Tokyo Night"]
        let items = titles.enumerated().map {
            DropdownItem(title: $0.element, group: nil, note: nil, isSelected: $0.offset == selectedIndex)
        }
        let dropdown = Dropdown(items: items, selectedIndex: selectedIndex, onChange: onChange)
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 400, width: 220, height: ChromeMetrics.Height.control)
        window.makeFirstResponder(dropdown)
        dropdown.openListForTesting()
        return dropdown
    }

    private func escape() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
    }

    func test_openingTheList_turnsTheButtonIntoAField() {
        let dropdown = filterFixture()

        XCTAssertTrue(dropdown.isEditingForTesting)

        NSApp.sendEvent(Self.escape(in: dropdown.window!))
        XCTAssertFalse(dropdown.isEditingForTesting, "closing hands the button back to its title")
    }

    func test_typing_filtersTheListToMatches() {
        let dropdown = filterFixture()

        dropdown.typeForTesting("nor")

        XCTAssertEqual(dropdown.queryForTesting, "nor")
        XCTAssertEqual(
            dropdown.visibleIndicesForTesting.map { dropdown.itemsForTesting[$0].title }, ["Nord"])
    }

    func test_clearingTheField_restoresTheWiderList() {
        let dropdown = filterFixture()
        dropdown.typeForTesting("nor")

        dropdown.typeForTesting("")

        XCTAssertEqual(dropdown.visibleIndicesForTesting.count, 5)
    }

    func test_escape_clearsTheQueryBeforeClosingTheList() {
        let dropdown = filterFixture()
        dropdown.typeForTesting("n")

        NSApp.sendEvent(Self.escape(in: dropdown.window!))
        XCTAssertEqual(dropdown.queryForTesting, "")
        XCTAssertTrue(dropdown.isPopoverOpen, "the first Esc clears the filter, it does not close")

        NSApp.sendEvent(Self.escape(in: dropdown.window!))
        XCTAssertFalse(dropdown.isPopoverOpen)
    }

    func test_arrowsAndReturn_reachTheListWhileTheFieldHasFocus() {
        var picked: Int?
        let dropdown = filterFixture { picked = $0 }
        dropdown.typeForTesting("gruvbox")

        XCTAssertTrue(dropdown.fieldCommandForTesting(#selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:))))

        XCTAssertEqual(picked, 1, "Down then Return took the second Gruvbox row")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Gruvbox Light")
    }

    func test_closingTheComboBox_returnsFocusSoArrowsStillWork() {
        var movedDown = false
        let dropdown = filterFixture()
        dropdown.onArrowDown = { movedDown = true }
        let window = dropdown.window

        NSApp.sendEvent(Self.escape(in: window!))

        XCTAssertFalse(dropdown.isPopoverOpen)
        XCTAssertFalse(dropdown.isEditingForTesting)
        XCTAssertTrue(window?.firstResponder === dropdown, "focus came back to the row, not the window")

        dropdown.keyDown(with: arrowDown())
        XCTAssertTrue(movedDown, "an arrow key moves on from the row once it has focus again")
    }

    private func arrowDown() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
    }

    func test_committingAFilteredRow_selectsThatItem_notItsPosition() {
        var picked: Int?
        let dropdown = filterFixture { picked = $0 }

        dropdown.typeForTesting("tok")
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(picked, 4, "committed the filtered row's own index")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Tokyo Night")
    }

    func test_aQueryWithNoMatches_commitsNothing() {
        var picked: Int?
        let dropdown = filterFixture { picked = $0 }

        dropdown.typeForTesting("zzz")
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(dropdown.visibleIndicesForTesting, [])
        XCTAssertNil(picked)
    }

    func test_aQueryWithNoMatches_saysSoRatherThanShowingASliver() {
        let dropdown = filterFixture()

        dropdown.typeForTesting("zzz")

        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.height, 20, "the card has to hold a line")
    }

    func test_typing_highlightsTheTopMatch_evenWhenTheSelectionStillMatches() {
        var picked: Int?
        let dropdown = filterFixture { picked = $0 }

        dropdown.typeForTesting("o")
        let ranked = dropdown.visibleIndicesForTesting
        XCTAssertTrue(ranked.contains(0), "the selection has to survive the query: \(ranked)")
        XCTAssertNotEqual(ranked.first, 0, "the selection has to rank below the top match: \(ranked)")

        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(picked, ranked.first, "Return takes the best match, as the palette does")
    }

    func test_escapeClearingTheQuery_returnsTheHighlightToTheSelection() {
        var picked: Int?
        let dropdown = filterFixture(selectedIndex: 2) { picked = $0 }
        dropdown.typeForTesting("g")
        XCTAssertNotEqual(
            dropdown.highlightedIndexForTesting, 2, "the query has to move the highlight off the selection")

        NSApp.sendEvent(Self.escape(in: dropdown.window!))
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(picked, 2, "Return after clearing the query changed the selection")
    }

    func test_arrowNavigation_scrollsHighlightIntoView() {
        let items = (0..<15).map {
            DropdownItem(title: "Theme \($0)", group: nil, note: nil, isSelected: $0 == 0)
        }
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 400, width: 220, height: ChromeMetrics.Height.control)

        dropdown.openListForTesting()
        for _ in 0..<(items.count - 1) { dropdown.moveHighlightForTesting(1) }

        XCTAssertTrue(dropdown.isHighlightedRowVisibleForTesting)
    }

    func test_arrowingDownPastTheFold_keepsTheHighlightClearOfTheFade() throws {
        let items = (0..<15).map {
            DropdownItem(title: "Theme \($0)", group: nil, note: nil, isSelected: $0 == 0)
        }
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 400, width: 220, height: ChromeMetrics.Height.control)

        dropdown.openListForTesting()
        for _ in 0..<9 { dropdown.moveHighlightForTesting(1) }

        let row = try XCTUnwrap(dropdown.highlightedRowForTesting)
        let scroll = try XCTUnwrap(row.enclosingScrollView as? FadingScrollView)
        let frame = row.convert(row.bounds, to: scroll.documentView)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 0, "precondition: the list has scrolled")
        XCTAssertGreaterThanOrEqual(
            scroll.documentVisibleRect.maxY - frame.maxY, scroll.fadeDepth - 0.5,
            "the highlighted row clears the bottom fade")
    }

    func test_openList_hangsBelowTheButton() {
        let dropdown = Self.dropdown(rows: 3)
        let window = Self.window(height: 400)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 320, width: 220, height: ChromeMetrics.Height.control)

        dropdown.openListForTesting()

        let card = dropdown.listCardFrameForTesting
        XCTAssertLessThanOrEqual(
            card.maxY, dropdown.frame.minY, "the list must hang below the button, not cover it")
    }

    func test_openList_nearTheWindowBottom_flipsAboveTheButton() {
        let dropdown = Self.dropdown(rows: 8)
        let window = Self.window(height: 400)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 24, width: 220, height: ChromeMetrics.Height.control)

        dropdown.openListForTesting()

        let card = dropdown.listCardFrameForTesting
        XCTAssertGreaterThanOrEqual(
            card.minY, dropdown.frame.maxY, "the list must flip above a button near the bottom")
        XCTAssertLessThanOrEqual(
            card.maxY, window.contentView!.bounds.height,
            "the flipped list must stay inside the window")
    }

    func test_resizingTheWindow_closesTheListAndTearsDownTheField() {
        let dropdown = Self.dropdown(rows: 4)
        let window = Self.window(height: 400)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 300, width: 220, height: ChromeMetrics.Height.control)
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen, "precondition: the list is up before the resize")
        XCTAssertEqual(
            dropdown.layer?.borderColor, Theme.current.chrome.focusRing.cgColor,
            "precondition: the button is lit while open")

        window.setFrame(NSRect(x: 0, y: 0, width: 520, height: 300), display: false)

        XCTAssertFalse(dropdown.isPopoverOpen, "the list must close rather than strand itself")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView },
            "no card left drawn on the content view after the resize")
        XCTAssertFalse(
            dropdown.isEditingForTesting, "the field is still showing under a list that is gone")
        XCTAssertEqual(dropdown.queryForTesting, "", "a stale query survived the resize")
    }

    private static func dropdown(rows: Int) -> Dropdown {
        let items = (0..<rows).map {
            DropdownItem(title: "Theme \($0)", group: nil, note: nil, isSelected: $0 == 0)
        }
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        return dropdown
    }

    private static func window(height: CGFloat) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    @MainActor
    func test_clickingAnOpenList_closesIt_ratherThanReopening() {
        let dropdown = filterFixture()
        XCTAssertTrue(dropdown.isPopoverOpen, "precondition")

        NSApp.sendEvent(Self.click(at: NSPoint(x: dropdown.frame.midX, y: dropdown.frame.midY), in: dropdown.window!))

        XCTAssertFalse(dropdown.isPopoverOpen, "the click reopened the list it just closed")
        XCTAssertFalse(dropdown.isEditingForTesting)
        XCTAssertTrue(dropdown.window?.firstResponder === dropdown, "the closed button keeps focus")
    }

    @MainActor
    func test_aClickOutsideTheList_closesIt() {
        let dropdown = filterFixture()
        dropdown.typeForTesting("n")

        NSApp.sendEvent(Self.click(at: NSPoint(x: 380, y: 20), in: dropdown.window!))

        XCTAssertFalse(dropdown.isPopoverOpen)
        XCTAssertFalse(dropdown.isEditingForTesting)
        XCTAssertEqual(dropdown.queryForTesting, "", "a stale query survived the click")
    }

    @MainActor
    func test_aClickOnTheButton_goesNoFurther() {
        let dropdown = filterFixture()
        let window = dropdown.window!
        let click = Self.click(at: NSPoint(x: dropdown.frame.midX, y: dropdown.frame.midY), in: window)

        XCTAssertNil(
            dropdown.listFilterForTesting(click), "the button's own click would reopen the list it just closed")
        XCTAssertFalse(dropdown.isPopoverOpen)
    }

    @MainActor
    func test_shiftEscape_stillClosesTheListFirst() {
        let dropdown = filterFixture()
        let window = dropdown.window!
        let shiftEscape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
            keyCode: 53)!

        NSApp.sendEvent(shiftEscape)

        XCTAssertFalse(dropdown.isPopoverOpen, "ModalEscape takes any Esc, so the list has to take it first")
    }

    @MainActor
    func test_escapeDuringComposition_leavesTheListForTheInputMethod() throws {
        let dropdown = filterFixture()
        let window = dropdown.window!
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setMarkedText(
            "k", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText(), "precondition: the query is mid-composition")

        NSApp.sendEvent(Self.escape(in: window))

        XCTAssertTrue(dropdown.isPopoverOpen, "the Esc belongs to the marked text")
    }

    @MainActor
    func test_aClickOnTheList_leavesItOpenForTheRow() {
        let dropdown = filterFixture()
        let card = dropdown.listCardFrameForTesting

        NSApp.sendEvent(Self.click(at: NSPoint(x: card.midX, y: card.maxY - 2), in: dropdown.window!))

        XCTAssertTrue(dropdown.isPopoverOpen, "a click inside the card's inset is not a click outside it")
    }

    @MainActor
    func test_tabbingOutOfAnOpenList_reachesTheFocusStop() {
        var tabbed = false
        let dropdown = filterFixture()
        dropdown.onTab = { tabbed = true }

        XCTAssertTrue(dropdown.fieldCommandForTesting(#selector(NSResponder.insertTab(_:))))

        XCTAssertTrue(tabbed, "Tab never reached the focus stop")
        XCTAssertFalse(dropdown.isPopoverOpen)
        XCTAssertFalse(dropdown.isEditingForTesting, "focus was left on the hidden field")
    }

    @MainActor
    func test_shiftTabbingOutOfAnOpenList_reachesTheBackFocusStop() {
        var backtabbed = false
        let dropdown = filterFixture()
        dropdown.onBacktab = { backtabbed = true }

        XCTAssertTrue(dropdown.fieldCommandForTesting(#selector(NSResponder.insertBacktab(_:))))

        XCTAssertTrue(backtabbed)
        XCTAssertFalse(dropdown.isEditingForTesting)
    }

    @MainActor
    func test_reapplyTheme_recolorsTheOpenFieldsText() throws {
        let original = Theme.current
        defer { Theme.setCurrentForTesting(original) }
        let dropdown = filterFixture()
        dropdown.typeForTesting("nor")
        let before = dropdown.queryFieldTextColorForTesting

        Theme.setCurrentForTesting(AppTheme(terminal: Self.contrastingTheme()))
        dropdown.reapplyThemeTree()

        XCTAssertNotEqual(
            dropdown.queryFieldTextColorForTesting, before, "the query stayed in the old theme")
        XCTAssertEqual(
            dropdown.queryFieldTextColorForTesting, Theme.current.chrome.ink(.normal))
    }

    @MainActor
    func test_reapplyTheme_rebuildsTheOpenListSoItIsNotStale() throws {
        let original = Theme.current
        defer { Theme.setCurrentForTesting(original) }
        let dropdown = filterFixture()
        dropdown.typeForTesting("nor")
        let staleRow = try XCTUnwrap(dropdown.rowFillsForTesting.first)

        Theme.setCurrentForTesting(AppTheme(terminal: Self.contrastingTheme()))
        dropdown.reapplyThemeTree()

        XCTAssertTrue(dropdown.isPopoverOpen, "the list has to survive the recolour")
        XCTAssertEqual(dropdown.queryForTesting, "nor", "the query survives the rebuild")
        XCTAssertNotEqual(
            dropdown.rowFillsForTesting.first, staleRow, "the list is still painted in the old theme")
    }

    private static func contrastingTheme() -> TerminalTheme {
        var theme = Theme.current.terminal
        theme.background = inverted(theme.background)
        theme.foreground = inverted(theme.foreground)
        return theme
    }

    private static func inverted(_ color: TerminalColor) -> TerminalColor {
        TerminalColor(red: 255 - color.red, green: 255 - color.green, blue: 255 - color.blue)
    }

    private static func click(at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func escape(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
            keyCode: 53)!
    }
}
