import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class DropdownTests: WindowTestCase {
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
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: 30)

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
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: 30)
        window.makeFirstResponder(dropdown)
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen)

        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        dropdown.keyDown(with: esc)

        XCTAssertFalse(dropdown.isPopoverOpen, "Esc in the dropdown's keyDown closes the list")
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
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: 30)
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

    private func filterFixture(onChange: @escaping (Int) -> Void = { _ in }) -> Dropdown {
        let titles = ["Gruvbox Dark", "Gruvbox Light", "Nord", "Rosé Pine", "Tokyo Night"]
        let items = titles.enumerated().map {
            DropdownItem(title: $0.element, group: nil, note: nil, isSelected: $0.offset == 0)
        }
        let dropdown = Dropdown(items: items, selectedIndex: 0, onChange: onChange)
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 400, width: 220, height: 30)
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

        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.cancelOperation(_:)))
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

        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(dropdown.queryForTesting, "")
        XCTAssertTrue(dropdown.isPopoverOpen, "the first Esc clears the filter, it does not close")

        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.cancelOperation(_:)))
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

        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.cancelOperation(_:)))

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
        dropdown.frame = NSRect(x: 20, y: 400, width: 220, height: 30)

        dropdown.openListForTesting()
        for _ in 0..<(items.count - 1) { dropdown.moveHighlightForTesting(1) }

        XCTAssertTrue(dropdown.isHighlightedRowVisibleForTesting)
    }

    func test_openList_hangsBelowTheButton() {
        let dropdown = Self.dropdown(rows: 3)
        let window = Self.window(height: 400)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 320, width: 220, height: 30)

        dropdown.openListForTesting()

        let card = dropdown.listCardFrameForTesting
        XCTAssertLessThanOrEqual(
            card.maxY, dropdown.frame.minY, "the list must hang below the button, not cover it")
    }

    func test_openList_nearTheWindowBottom_flipsAboveTheButton() {
        let dropdown = Self.dropdown(rows: 8)
        let window = Self.window(height: 400)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 24, width: 220, height: 30)

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
        dropdown.frame = NSRect(x: 20, y: 300, width: 220, height: 30)
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen, "precondition: the list is up before the resize")
        XCTAssertEqual(dropdown.layer?.borderWidth, 1.5, "precondition: the button is lit while open")

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

        dropdown.mouseDown(with: click())

        XCTAssertFalse(dropdown.isPopoverOpen, "the click reopened the list it just closed")
        XCTAssertFalse(dropdown.isEditingForTesting)
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
        dropdown.reapplyTheme()

        XCTAssertNotEqual(
            dropdown.queryFieldTextColorForTesting, before, "the query stayed in the old theme")
        XCTAssertEqual(
            dropdown.queryFieldTextColorForTesting, Theme.current.chrome.foreground.nsColor)
    }

    @MainActor
    func test_reapplyTheme_rebuildsTheOpenListSoItIsNotStale() throws {
        let original = Theme.current
        defer { Theme.setCurrentForTesting(original) }
        let dropdown = filterFixture()
        dropdown.typeForTesting("nor")
        let staleRow = try XCTUnwrap(dropdown.rowFillsForTesting.first)

        Theme.setCurrentForTesting(AppTheme(terminal: Self.contrastingTheme()))
        dropdown.reapplyTheme()

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

    private func click() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
