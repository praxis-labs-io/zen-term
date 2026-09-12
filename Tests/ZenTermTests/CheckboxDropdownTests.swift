import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the multi-select checkbox dropdown: drive the real control in a
/// window — its actual `keyDown` and row `mouseDown` — and assert what it reports and fires. A
/// state-only test would pass while the rows were dead, the exact failure mode the project's
/// interaction-test rule guards against.
final class CheckboxDropdownTests: WindowTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func makeDropdown(
        _ titles: [String] = ["One", "Two", "Three"], onToggle: @escaping (Int) -> Void = { _ in }
    ) -> CheckboxDropdown {
        let dropdown = CheckboxDropdown(
            title: "All shown",
            items: titles.map { CheckboxDropdownItem(title: $0, isChecked: true) },
            onToggle: onToggle)
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 320, width: 220, height: 30)
        win.layoutIfNeeded()
        window = win
        win.makeFirstResponder(dropdown)
        return dropdown
    }

    private func press(_ dropdown: CheckboxDropdown, _ chars: String, code: UInt16, shift: Bool = false) {
        dropdown.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code)!)
    }

    // MARK: type to filter

    /// A carry list is as long as the repo's `.gitignore`, which is past what arrowing can reach.
    func test_typing_narrowsTheListAndShowsTheQuery() {
        let dropdown = makeDropdown([".env", "node_modules", "config/credentials/development.key"])
        press(dropdown, " ", code: 49)

        press(dropdown, "c", code: 8)
        press(dropdown, "r", code: 15)

        XCTAssertEqual(dropdown.queryForTesting, "cr")
        XCTAssertEqual(dropdown.visibleIndicesForTesting, [2], "fuzzy, the way the palette matches")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "cr", "the button shows what is being typed")
    }

    /// The one deliberate divergence from `Dropdown`: this list commits with Space, so a query
    /// never holds one. Typing past a filter must not silently stop toggling.
    func test_space_stillTogglesRatherThanTypingIntoTheQuery() {
        var toggled: [Int] = []
        let dropdown = makeDropdown([".env", "node_modules"], onToggle: { toggled.append($0) })
        press(dropdown, " ", code: 49)  // open
        press(dropdown, "m", code: 46)  // filter to node_modules
        press(dropdown, "o", code: 31)
        press(dropdown, "d", code: 2)

        press(dropdown, " ", code: 49)

        XCTAssertEqual(dropdown.queryForTesting, "mod", "Space never enters the query")
        XCTAssertEqual(toggled, [1], "it toggles the highlighted row, by catalog index")
    }

    func test_backspace_widensTheListAgain() {
        let dropdown = makeDropdown([".env", "node_modules"])
        press(dropdown, " ", code: 49)
        press(dropdown, "n", code: 45)
        XCTAssertEqual(dropdown.visibleIndicesForTesting, [1, 0])

        press(dropdown, "", code: 51)  // backspace

        XCTAssertEqual(dropdown.queryForTesting, "")
        XCTAssertEqual(dropdown.visibleIndicesForTesting, [0, 1])
    }

    /// Esc clears a mistyped query before it closes anything, so recovering is not a reopen.
    func test_escape_clearsTheQueryBeforeItClosesTheList() {
        let dropdown = makeDropdown([".env", "node_modules"])
        press(dropdown, " ", code: 49)
        press(dropdown, "n", code: 45)

        press(dropdown, "", code: 53)
        XCTAssertTrue(dropdown.isPopoverOpen, "the first Esc clears")
        XCTAssertEqual(dropdown.queryForTesting, "")

        press(dropdown, "", code: 53)
        XCTAssertFalse(dropdown.isPopoverOpen, "the second closes")
    }

    func test_arrowsWalkOnlyWhatTheQueryAdmits() {
        var toggled: [Int] = []
        let dropdown = makeDropdown([".env", "node_modules", "nested"], onToggle: { toggled.append($0) })
        press(dropdown, " ", code: 49)
        press(dropdown, "n", code: 45)
        press(dropdown, "e", code: 14)
        press(dropdown, "s", code: 1)
        let admitted = dropdown.visibleIndicesForTesting
        XCTAssertFalse(admitted.contains(0), ".env is filtered out: \(admitted)")

        press(dropdown, "", code: 125)  // Down, within the filtered set
        press(dropdown, "\r", code: 36)  // Return toggles

        XCTAssertEqual(toggled, [admitted[1]], "a filtered-out row is never reachable")
        XCTAssertGreaterThan(admitted.count, 1, "the query has to leave more than one row to walk")
    }

    func test_reopening_startsWithNoQuery() {
        let dropdown = makeDropdown([".env", "node_modules"])
        press(dropdown, " ", code: 49)
        press(dropdown, "n", code: 45)
        press(dropdown, "", code: 53)  // clear
        press(dropdown, "", code: 53)  // close

        press(dropdown, " ", code: 49)

        XCTAssertEqual(dropdown.queryForTesting, "")
        XCTAssertEqual(dropdown.visibleIndicesForTesting, [0, 1])
        XCTAssertEqual(dropdown.buttonTitleForTesting, "All shown")
    }

    /// A query that admits nothing rendered a 12pt sliver with no text in it, because the card
    /// sized itself to zero rows.
    func test_aQueryThatMatchesNothing_saysSoRatherThanShowingASliver() {
        let dropdown = makeDropdown([".env", "node_modules"])
        press(dropdown, " ", code: 49)

        press(dropdown, "z", code: 6)
        press(dropdown, "q", code: 12)

        XCTAssertEqual(dropdown.visibleIndicesForTesting, [])
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.height, 20, "the card has to hold a line")
    }

    /// The highlight survives a query that admits nothing, so Space was committing a row the user
    /// could not see. In the copy list that wrote a path into the workspace on save.
    func test_spaceWithNothingMatching_togglesNothing() {
        var toggled: [Int] = []
        let dropdown = makeDropdown([".env", "node_modules"], onToggle: { toggled.append($0) })
        press(dropdown, " ", code: 49)
        press(dropdown, "z", code: 6)

        press(dropdown, " ", code: 49)
        press(dropdown, "\r", code: 36)

        XCTAssertEqual(toggled, [], "a filtered-out row is not committable")
    }

    /// `KeyboardFocus.key` decodes eight keycodes; Home, End, the page keys and every F-key fall
    /// past it carrying a private-use scalar, which `Character` calls printable. Unfiltered they
    /// entered the query, emptied the list and rendered the button as tofu.
    func test_theNonPrintingKeys_doNotEnterTheQuery() {
        let dropdown = makeDropdown([".env", "node_modules"])
        press(dropdown, " ", code: 49)

        for (glyph, code) in [("\u{F729}", UInt16(115)), ("\u{F72B}", 119), ("\u{F72C}", 116)] {
            press(dropdown, glyph, code: code)
        }

        XCTAssertEqual(dropdown.queryForTesting, "")
        XCTAssertEqual(dropdown.visibleIndicesForTesting, [0, 1])
    }

    /// A window resize closes the card without going through `closeList`, so everything hanging off
    /// a close has to happen there too or the button keeps its accent query text.
    func test_aResizeClosingTheList_clearsTheQueryAndFiresOnClosed() {
        var closed = 0
        let dropdown = makeDropdown([".env", "node_modules"])
        dropdown.onClosed = { closed += 1 }
        press(dropdown, " ", code: 49)
        press(dropdown, "n", code: 45)
        XCTAssertEqual(dropdown.queryForTesting, "n")

        window?.setFrame(NSRect(x: 0, y: 0, width: 500, height: 500), display: false)

        XCTAssertFalse(dropdown.isPopoverOpen)
        XCTAssertEqual(dropdown.queryForTesting, "")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "All shown")
        XCTAssertEqual(closed, 1, "a waiting owner has to hear about it")
    }

    func test_spaceOpensTheList_withVisibleCard() {
        let dropdown = makeDropdown()
        XCTAssertFalse(dropdown.isPopoverOpen)
        press(dropdown, " ", code: 49)
        XCTAssertTrue(dropdown.isPopoverOpen)
        // The regression Dropdown shipped once: a card that renders at ~zero size (invisible list).
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.height, 0)
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.width, 0)
    }

    func test_closedArrows_bubbleToTheForm_openArrowsMoveTheHighlight() {
        var bubbledUp = 0
        var bubbledDown = 0
        let dropdown = makeDropdown()
        dropdown.onArrowUp = { bubbledUp += 1 }
        dropdown.onArrowDown = { bubbledDown += 1 }

        press(dropdown, "", code: 126)  // closed: Up bubbles
        press(dropdown, "", code: 125)  // closed: Down bubbles
        XCTAssertEqual(bubbledUp, 1)
        XCTAssertEqual(bubbledDown, 1)

        press(dropdown, " ", code: 49)  // open
        press(dropdown, "", code: 125)  // open: Down moves the highlight, not the focus
        XCTAssertEqual(dropdown.highlightedIndexForTesting, 1)
        XCTAssertEqual(bubbledDown, 1, "an open list owns its arrows")
    }

    /// The multi-select contract: a toggle reports and the list STAYS open, so several buttons can
    /// be toggled in one visit — the single-select commit-and-close would eject the user each pick.
    func test_spaceTogglesTheHighlightedRow_andKeepsTheListOpen() {
        var toggled: [Int] = []
        let dropdown = makeDropdown(onToggle: { toggled.append($0) })
        press(dropdown, " ", code: 49)  // open
        press(dropdown, "", code: 125)  // highlight row 1
        press(dropdown, " ", code: 49)  // toggle it
        XCTAssertEqual(toggled, [1])
        XCTAssertTrue(dropdown.isPopoverOpen, "a toggle must not close a multi-select")
    }

    func test_escClosesTheList_withoutToggling() {
        var toggled: [Int] = []
        let dropdown = makeDropdown(onToggle: { toggled.append($0) })
        press(dropdown, " ", code: 49)
        press(dropdown, "\u{1b}", code: 53)
        XCTAssertFalse(dropdown.isPopoverOpen)
        XCTAssertEqual(toggled, [])
    }

    func test_focusLossClosesTheList() {
        let dropdown = makeDropdown()
        press(dropdown, " ", code: 49)
        XCTAssertTrue(dropdown.isPopoverOpen)
        window?.makeFirstResponder(nil)
        XCTAssertFalse(dropdown.isPopoverOpen, "an outside click moves focus, which must close the list")
    }

    func test_tabAndLeft_bubbleWhileClosed() {
        var lefts = 0
        var tabs = 0
        var backtabs = 0
        let dropdown = makeDropdown()
        dropdown.onArrowLeft = { lefts += 1 }
        dropdown.onTab = { tabs += 1 }
        dropdown.onBacktab = { backtabs += 1 }

        press(dropdown, "", code: 123)
        press(dropdown, "\t", code: 48)
        press(dropdown, "\t", code: 48, shift: true)
        XCTAssertEqual(lefts, 1)
        XCTAssertEqual(tabs, 1)
        XCTAssertEqual(backtabs, 1)
    }

    /// Clicking a row toggles it and keeps the list open — driven through the row's real
    /// `mouseDown`, the same layer the palette's click tests drive (OS hit-testing down to the row
    /// is AppKit's job, not ours).
    func test_clickTogglesTheClickedRow_andKeepsTheListOpen() {
        var toggled: [Int] = []
        let dropdown = makeDropdown(onToggle: { toggled.append($0) })
        dropdown.openListForTesting()
        let row = dropdown.rowViewsForTesting[2]
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: row.convert(CGPoint(x: 4, y: 4), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: row.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        row.mouseDown(with: event)
        XCTAssertEqual(toggled, [2])
        XCTAssertTrue(dropdown.isPopoverOpen)
    }

    /// The row count is fixed at init: a longer array must clamp, or arrow keys walk past the last
    /// rendered row and Space toggles an entry the user cannot see.
    /// A second open must not rebuild the rows. The card is already up, so fresh row views would
    /// be mounted nowhere: the rows on screen stop repainting and the highlight moves through views
    /// the user cannot see.
    func test_openingTwice_leavesTheMountedRowsInPlace() {
        let dropdown = makeDropdown()

        dropdown.openListForTesting()
        dropdown.openListForTesting()

        XCTAssertTrue(dropdown.isPopoverOpen)
        for row in dropdown.rowViewsForTesting {
            XCTAssertNotNil(row.window, "a row view is detached, so the list on screen is stale")
        }
    }

    func test_setItems_clampsToTheInitRowCount() {
        let dropdown = makeDropdown(["One", "Two", "Three"])
        dropdown.setItems(
            ["One", "Two", "Three", "Four"].map { CheckboxDropdownItem(title: $0, isChecked: true) },
            title: "All shown")
        XCTAssertEqual(dropdown.itemsForTesting.count, 3)
    }

    /// The first row must render its highlight the moment the list opens — not after the first
    /// arrow move. (The bug: painting from inside the card build, before `listCard` was assigned,
    /// while the highlight gates on `listCard != nil`.)
    func test_openList_rendersTheInitialHighlight() {
        let dropdown = makeDropdown()
        dropdown.openListForTesting()
        let highlightFill = Theme.current.chrome.fill(.hover).cgColor
        XCTAssertEqual(dropdown.rowViewsForTesting.first?.layer?.backgroundColor, highlightFill)
    }

    func test_setItems_updatesTitleAndRows_withoutFiringOnToggle() {
        var toggled: [Int] = []
        let dropdown = makeDropdown(onToggle: { toggled.append($0) })
        dropdown.openListForTesting()
        dropdown.setItems(
            [
                CheckboxDropdownItem(title: "One", isChecked: false),
                CheckboxDropdownItem(title: "Two", isChecked: true),
                CheckboxDropdownItem(title: "Three", isChecked: false),
            ], title: "2 hidden")
        XCTAssertEqual(toggled, [])
        XCTAssertEqual(dropdown.buttonTitleForTesting, "2 hidden")
        XCTAssertEqual(dropdown.itemsForTesting.map(\.isChecked), [false, true, false])
        XCTAssertTrue(dropdown.isPopoverOpen, "a reload's re-sync must not eject an open list")
    }
}
