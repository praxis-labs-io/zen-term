import XCTest

@testable import ZenTerm

final class BranchFieldTests: XCTestCase {
    private var window: NSWindow!
    private var field: BranchField!

    override func setUp() {
        super.setUp()
        field = BranchField()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 20, y: 300, width: 420, height: ChromeMetrics.Height.control)
        window.contentView?.layoutSubtreeIfNeeded()
        field.setBranches(
            ["main", "feature/zen-454", "feature/zen-481", "refactor/flags"], notes: [:])
    }

    override func tearDown() {
        field.closeList()
        window = nil
        field = nil
        super.tearDown()
    }

    private func type(_ text: String) {
        field.box.setText(text)
        field.box.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field.box.field))
    }

    private func pressEscape() {
        NSApp.sendEvent(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
    }

    private func fieldClaimsEscape() -> Bool {
        field.box.control(
            field.box.field, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    private func arrow(_ key: UInt16) {
        field.box.control(
            field.box.field, textView: NSTextView(),
            doCommandBy: key == 126 ? #selector(NSResponder.moveUp(_:)) : #selector(NSResponder.moveDown(_:)))
    }

    func test_typing_opensTheListFilteredByTheQuery() {
        type("zen")

        XCTAssertTrue(field.isListOpen)
        XCTAssertEqual(field.matchesForTesting, ["feature/zen-454", "feature/zen-481"])
    }

    func test_anExactMatch_leadsTheList() {
        type("feature/zen-45")

        XCTAssertEqual(field.matchesForTesting.first, "feature/zen-454")
    }

    func test_aQueryThatIsAlreadyTheOnlyMatch_closesTheList() {
        type("feature/zen-454")

        XCTAssertFalse(field.isListOpen)
    }

    func test_anExactMatchWithOtherCandidates_keepsTheList() {
        field.setBranches(["main", "main-ish"], notes: [:])

        type("main")

        XCTAssertTrue(field.isListOpen)
        XCTAssertEqual(field.matchesForTesting.first, "main")
    }

    func test_aQueryThatMatchesNothing_showsNoList() {
        type("zen")
        XCTAssertTrue(field.isListOpen)

        type("qqqq")

        XCTAssertFalse(field.isListOpen)
        XCTAssertTrue(field.matchesForTesting.isEmpty)
    }

    func test_downMovesTheHighlightWhileTheListIsOpen() {
        type("zen")

        arrow(125)

        XCTAssertEqual(field.highlightedForTesting, "feature/zen-481")
    }

    func test_downLeavesTheFieldWhenNothingMatches() {
        var left = 0
        field.onArrowDown = { left += 1 }
        type("qqqq")

        arrow(125)

        XCTAssertEqual(left, 1)
    }

    func test_downOnAnEmptyFieldOpensTheWholeList() {
        var left = 0
        field.onArrowDown = { left += 1 }

        arrow(125)

        XCTAssertTrue(field.isListOpen)
        XCTAssertEqual(field.matchesForTesting.count, 4)
        XCTAssertEqual(left, 0, "the arrow opened the list rather than leaving the field")
    }

    func test_returnCommitsTheHighlightedBranch() {
        var advanced = 0
        field.onEnter = { advanced += 1 }
        type("zen")
        arrow(125)

        field.box.onEnter?()

        XCTAssertEqual(field.text, "feature/zen-481")
        XCTAssertFalse(field.isListOpen)
        XCTAssertEqual(advanced, 0, "Return picked a branch rather than moving on")
    }

    func test_returnWithNoListAdvancesTheForm() {
        var advanced = 0
        field.onEnter = { advanced += 1 }
        type("qqqq")

        field.box.onEnter?()

        XCTAssertEqual(advanced, 1)
    }

    func test_escapeTakesTheListDownAndKeepsTheCard() {
        type("zen")

        pressEscape()

        XCTAssertFalse(field.isListOpen)
        XCTAssertEqual(field.text, "zen")
    }

    func test_aClickInTheField_closesTheListAndReachesTheField() {
        type("zen")
        let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!

        XCTAssertTrue(field.listFilterForTesting(click) === click, "the click goes on to place the caret")
        XCTAssertFalse(field.isListOpen)
    }

    func test_escapeWithNoListIsNotConsumed() {
        type("qqqq")

        XCTAssertFalse(fieldClaimsEscape(), "Esc goes on to the card, which closes")
    }

    func test_closingTheListLeavesTheTypedTextAlone() {
        type("zen")

        field.closeList()

        XCTAssertFalse(field.isListOpen)
        XCTAssertEqual(field.text, "zen")
    }

    func test_aHeldBranchKeepsItsRowAndItsNote() {
        let note = NewWorktreeOverlay.branchNote(for: .worktree(URL(fileURLWithPath: "/tmp/wt")))
        field.setBranches(["feature/zen-454"], notes: ["feature/zen-454": note])

        type("zen")

        XCTAssertEqual(field.matchesForTesting, ["feature/zen-454"])
        XCTAssertTrue(noteText().contains("has a worktree"))
    }

    func test_aBranchTheMainCheckoutHoldsSaysSoOnItsRow() {
        let note = NewWorktreeOverlay.branchNote(for: .mainCheckout(URL(fileURLWithPath: "/tmp/repo")))
        field.setBranches(["feature/zen-454"], notes: ["feature/zen-454": note])

        type("zen")

        XCTAssertTrue(noteText().contains("main checkout"))
    }

    func test_tabTakesTheListDownOnTheWayOut() {
        var left = 0
        field.onTab = { left += 1 }
        type("zen")

        field.box.onTab?()

        XCTAssertFalse(field.isListOpen)
        XCTAssertEqual(left, 1)
    }

    func test_leavingTheWindowTakesTheListWithIt() {
        type("zen")

        field.removeFromSuperview()

        XCTAssertFalse(field.isListOpen)
    }

    private func noteText() -> [String] {
        guard let content = window.contentView else { return [] }
        return descendants(of: content)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isEditable && !$0.isHidden }
            .map(\.stringValue)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
