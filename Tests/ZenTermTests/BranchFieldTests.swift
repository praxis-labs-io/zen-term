import XCTest

@testable import ZenTerm

/// The branch field's suggestion list, driven through the real control in a real window: the list
/// is parented to the window's content view, so nothing here works without one.
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
        field.frame = NSRect(x: 20, y: 300, width: 420, height: 30)
        window.contentView?.layoutSubtreeIfNeeded()
        field.setBranches(
            ["main", "feature/zen-454", "feature/zen-481", "refactor/flags"], holders: [:])
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

    /// The name the user typed in full is the one they meant, whatever the scorer says.
    func test_anExactMatch_leadsTheList() {
        type("main")

        XCTAssertEqual(field.matchesForTesting.first, "main")
    }

    /// An empty filtered list renders as a bare sliver, which is worse than no list at all.
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

    /// With nothing to suggest the arrow belongs to the form, not to the field.
    func test_downLeavesTheFieldWhenNothingMatches() {
        var left = 0
        field.onArrowDown = { left += 1 }
        type("qqqq")

        arrow(125)

        XCTAssertEqual(left, 1)
    }

    /// The entry point for "give an existing branch a worktree": nothing typed, everything offered.
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

    func test_closingTheListLeavesTheTypedTextAlone() {
        type("zen")

        field.closeList()

        XCTAssertFalse(field.isListOpen)
        XCTAssertEqual(field.text, "zen")
    }

    /// A branch something already holds keeps its row: hiding it leaves the user typing the name
    /// by hand and meeting the refusal with no explanation.
    func test_aHeldBranchKeepsItsRowAndItsNote() {
        field.setBranches(
            ["feature/zen-454"],
            holders: ["feature/zen-454": .worktree(URL(fileURLWithPath: "/tmp/wt"))])

        type("zen")

        XCTAssertEqual(field.matchesForTesting, ["feature/zen-454"])
        XCTAssertTrue(noteText().contains("has a worktree"))
    }

    func test_aBranchTheMainCheckoutHoldsSaysSoOnItsRow() {
        field.setBranches(
            ["feature/zen-454"],
            holders: ["feature/zen-454": .mainCheckout(URL(fileURLWithPath: "/tmp/repo"))])

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

    /// The list is parented to the window's content view, so nothing takes it down with the field.
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
