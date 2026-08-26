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
        // The regression: the card must have real size, not collapse to ~zero (invisible list).
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.height, 0)
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.width, 0)
    }

    /// A bare Esc over an open list closes it at the real dispatch layer — the dropdown's own
    /// `keyDown`, which AppKit reaches before any card-root `performKeyEquivalent` (confirmed
    /// in the running app). The event is built the way AppKit delivers a bare Esc (keyCode 53, no
    /// modifiers). Driving the real keyDown is the point: a `performKeyEquivalent`-by-hand test would
    /// pass even with this handler gone, since that layer never runs for a bare Esc while the
    /// dropdown holds focus.
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

    /// The open list card lives on `window.contentView`, not inside the dropdown's own
    /// subtree, so tearing the dropdown's host out of the window (what a tab-switch `closeModal()`
    /// does to the Settings card) must still take the card with it. Without a leave-the-window hook
    /// the card orphans on the content view — stuck on every tab, no way to clear but restart.
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
        // Host the dropdown inside a container standing in for the Settings modal overlay, so the
        // teardown removes an ANCESTOR of the dropdown (not the dropdown directly) — exactly the
        // `closeModal()` path.
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(host)
        host.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: 30)
        window.makeFirstResponder(dropdown)
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen)
        XCTAssertTrue(window.contentView!.subviews.contains { $0 is ShadowCardView })

        host.removeFromSuperview()  // the Settings card being torn down out from under the dropdown

        XCTAssertFalse(dropdown.isPopoverOpen, "list closes when the dropdown leaves the window")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView },
            "no orphaned list card left drawn on the content view")
    }

    // MARK: - type to filter

    /// Sixty-five themes is past what arrowing can manage, so the button becomes a search field when
    /// the list opens: a combo box. Driven through the real field and the real delegate, because a
    /// state-only test passes while the field is never wired to the filter.
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

    /// Opening turns the button into an input. Without this the filter has no caret and no field,
    /// which is a hint rather than a control.
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

    /// Esc clears a mistyped filter before it closes anything, so recovering does not mean reopening.
    func test_escape_clearsTheQueryBeforeClosingTheList() {
        let dropdown = filterFixture()
        dropdown.typeForTesting("n")

        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(dropdown.queryForTesting, "")
        XCTAssertTrue(dropdown.isPopoverOpen, "the first Esc clears the filter, it does not close")

        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(dropdown.isPopoverOpen)
    }

    /// The field editor swallows arrows and Return, so the list's own keys have to be taken back
    /// from it. Without that the highlight cannot move and nothing can be committed by keyboard.
    func test_arrowsAndReturn_reachTheListWhileTheFieldHasFocus() {
        var picked: Int?
        let dropdown = filterFixture { picked = $0 }
        dropdown.typeForTesting("gruvbox")

        XCTAssertTrue(dropdown.fieldCommandForTesting(#selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:))))

        XCTAssertEqual(picked, 1, "Down then Return took the second Gruvbox row")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Gruvbox Light")
    }

    /// Closing the combo box has to hand focus back, or the row is a dead end: Esc shut the list and
    /// left focus on the window, where no arrow key reaches anything. Asserts the responder *and*
    /// that an arrow actually moves from here, which is the thing the user notices.
    func test_closingTheComboBox_returnsFocusSoArrowsStillWork() {
        var movedDown = false
        let dropdown = filterFixture()
        dropdown.onArrowDown = { movedDown = true }
        let window = dropdown.window

        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.cancelOperation(_:)))  // closes, query empty

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

    /// The bug this design invites: rows are rebuilt in filtered order, so committing by position
    /// would report whatever item sat at that index unfiltered. "Tokyo Night" is index 4 of 5 and
    /// the only match for "tok", so a position-based commit hands back index 0.
    func test_committingAFilteredRow_selectsThatItem_notItsPosition() {
        var picked: Int?
        let dropdown = filterFixture { picked = $0 }

        dropdown.typeForTesting("tok")
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(picked, 4, "committed the filtered row's own index")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Tokyo Night")
    }

    /// A query matching nothing commits nothing rather than picking a stale highlight.
    func test_aQueryWithNoMatches_commitsNothing() {
        var picked: Int?
        let dropdown = filterFixture { picked = $0 }

        dropdown.typeForTesting("zzz")
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(dropdown.visibleIndicesForTesting, [])
        XCTAssertNil(picked)
    }

    func test_arrowNavigation_scrollsHighlightIntoView() {
        // 15 rows overflow the ~260pt list cap, so the last row starts below the fold.
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
        // Walk the highlight down to the last item, past the visible cap.
        for _ in 0..<(items.count - 1) { dropdown.moveHighlightForTesting(1) }

        // Regression: the highlighted row must have been scrolled into view, not left below the fold.
        XCTAssertTrue(dropdown.isHighlightedRowVisibleForTesting)
    }

    /// The list prefers to hang below the button, which is the case a reader checks by eye and the
    /// one every picker in Settings hits.
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

    /// A picker near the bottom of the window has no room below it, so the card flips above rather
    /// than drawing off the window. Nothing covered this geometry, and it is the half of
    /// `positionList` that only shows on a short window or a picker low in a long form.
    func test_openList_nearTheWindowBottom_flipsAboveTheButton() {
        let dropdown = Self.dropdown(rows: 8)
        let window = Self.window(height: 400)
        window.contentView?.addSubview(dropdown)
        // 24pt off the bottom: less than the card's height, so "below" would run off the window.
        dropdown.frame = NSRect(x: 20, y: 24, width: 220, height: 30)

        dropdown.openListForTesting()

        let card = dropdown.listCardFrameForTesting
        XCTAssertGreaterThanOrEqual(
            card.minY, dropdown.frame.maxY, "the list must flip above a button near the bottom")
        XCTAssertLessThanOrEqual(
            card.maxY, window.contentView!.bounds.height,
            "the flipped list must stay inside the window")
    }

    /// The card is placed once, at open, so a resize leaves it stranded where the button used to be.
    /// It closes instead, and the whole editing session has to come down with it.
    ///
    /// The border no longer discriminates: opening a combo box always takes first responder, and
    /// `lit` is `isFocused || isOpen`, so the button stays lit either way. What a resize can still get
    /// wrong is the *field* — left showing, holding a stale query, with focus stranded on it and
    /// typing dead because `rerenderList` bails on a closed list. That is asserted instead.
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

    // MARK: - closing paths

    /// Clicking the button while the list is open closes it. Taking first responder ends the field's
    /// editing session, which closes the list synchronously, so a ternary tested *after* that always
    /// saw a closed list and reopened the one it had just shut. Click-to-dismiss was gone from every
    /// dropdown in Settings, and `hitTest` routes clicks on the field here too, so nothing inside the
    /// control could dismiss it.
    @MainActor
    func test_clickingAnOpenList_closesIt_ratherThanReopening() {
        let dropdown = filterFixture()
        XCTAssertTrue(dropdown.isPopoverOpen, "precondition")

        dropdown.mouseDown(with: click())

        XCTAssertFalse(dropdown.isPopoverOpen, "the click reopened the list it just closed")
        XCTAssertFalse(dropdown.isEditingForTesting)
    }

    /// Tab has to reach the form's focus stop. Left to AppKit, `selectNextKeyView` ends editing —
    /// closing the list, which hands focus back — and then overwrites that with its own choice. No
    /// form in this app builds a `nextKeyView` chain, so focus landed on the hidden field and the
    /// keyboard was dead until the user clicked.
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

    /// The field outlives a theme change while the list is open, so its text and placeholder go stale
    /// in the previous theme's foreground — the hardcoded-colour failure this repo bans. On a
    /// dark-to-light swap the typed query goes near-invisible.
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

    private static func contrastingTheme() -> TerminalTheme {
        var theme = Theme.rosePineZen
        theme.background = TerminalColor(red: 0xFA, green: 0xF4, blue: 0xED)
        theme.foreground = TerminalColor(red: 0x57, green: 0x52, blue: 0x79)
        return theme
    }

    private func click() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
