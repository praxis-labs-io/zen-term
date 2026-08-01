import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the multi-select checkbox list (ZEN-327): drive the real control in a
/// window — its actual `keyDown` and row `mouseDown` — and assert what it reports and fires. A
/// state-only test would pass while the rows were dead, the exact failure mode the project's
/// interaction-test rule guards against.
final class CheckboxListTests: WindowTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func makeList(
        _ titles: [String] = ["One", "Two", "Three"], onToggle: @escaping (Int) -> Void = { _ in }
    ) -> CheckboxList {
        let list = CheckboxList(
            items: titles.map { CheckboxListItem(title: $0, isChecked: true) }, onToggle: onToggle)
        list.translatesAutoresizingMaskIntoConstraints = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(list)
        list.frame = NSRect(x: 20, y: 40, width: 220, height: 200)
        win.layoutIfNeeded()
        window = win
        win.makeFirstResponder(list)
        return list
    }

    private func keyDown(_ chars: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: code)!
    }

    private func press(_ list: CheckboxList, _ chars: String, code: UInt16) {
        list.keyDown(with: keyDown(chars, code: code))
    }

    func test_arrowsMoveHighlight_andBubbleAtTheBoundaries() {
        var bubbledUp = 0
        var bubbledDown = 0
        let list = makeList()
        list.onArrowUp = { bubbledUp += 1 }
        list.onArrowDown = { bubbledDown += 1 }

        XCTAssertEqual(list.highlightedIndexForTesting, 0)
        press(list, "", code: 126)  // Up on the first row leaves the control
        XCTAssertEqual(bubbledUp, 1)

        press(list, "", code: 125)  // Down moves the highlight, not the focus
        press(list, "", code: 125)
        XCTAssertEqual(list.highlightedIndexForTesting, 2)
        XCTAssertEqual(bubbledDown, 0)

        press(list, "", code: 125)  // Down on the last row leaves the control
        XCTAssertEqual(bubbledDown, 1)
        XCTAssertEqual(list.highlightedIndexForTesting, 2)
    }

    func test_spaceTogglesTheHighlightedRow() {
        var toggled: [Int] = []
        let list = makeList(onToggle: { toggled.append($0) })
        press(list, "", code: 125)  // highlight row 1
        press(list, " ", code: 49)  // space
        XCTAssertEqual(toggled, [1])
    }

    func test_returnAlsoToggles() {
        var toggled: [Int] = []
        let list = makeList(onToggle: { toggled.append($0) })
        press(list, "\r", code: 36)
        XCTAssertEqual(toggled, [0])
    }

    func test_leftAndTab_bubbleToTheForm() {
        var lefts = 0
        var tabs = 0
        var backtabs = 0
        let list = makeList()
        list.onArrowLeft = { lefts += 1 }
        list.onTab = { tabs += 1 }
        list.onBacktab = { backtabs += 1 }

        press(list, "", code: 123)  // left
        press(list, "\t", code: 48)  // tab
        list.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48)!)
        XCTAssertEqual(lefts, 1)
        XCTAssertEqual(tabs, 1)
        XCTAssertEqual(backtabs, 1)
    }

    /// Clicking a row toggles it — driven through the row's real `mouseDown`, the same layer the
    /// palette's click tests drive (OS hit-testing down to the row is AppKit's job, not ours).
    func test_clickTogglesTheClickedRow() {
        var toggled: [Int] = []
        let list = makeList(onToggle: { toggled.append($0) })
        let row = list.rowViewsForTesting[2]
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: row.convert(CGPoint(x: 4, y: 4), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: row.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        row.mouseDown(with: event)
        XCTAssertEqual(toggled, [2])
    }

    func test_setItems_rendersWithoutFiringOnToggle() {
        var toggled: [Int] = []
        let list = makeList(onToggle: { toggled.append($0) })
        list.setItems([
            CheckboxListItem(title: "One", isChecked: false),
            CheckboxListItem(title: "Two", isChecked: true),
            CheckboxListItem(title: "Three", isChecked: false),
        ])
        XCTAssertEqual(toggled, [])
        XCTAssertEqual(list.itemsForTesting.map(\.isChecked), [false, true, false])
    }
}
