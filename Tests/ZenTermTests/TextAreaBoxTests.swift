import AppKit
import XCTest

@testable import ZenTerm

/// Unit tests for the multiline input's keyboard-boundary handling, driven through the real
/// `doCommandBy` path (not the focus-ring closures), so the caret-position logic that decides whether
/// an arrow leaves the field is actually exercised.
final class TextAreaBoxTests: XCTestCase {
    private func box(_ text: String, caret: Int) -> TextAreaBox {
        let box = TextAreaBox(placeholder: "x")
        box.setText(text)
        box.textView.setSelectedRange(NSRange(location: caret, length: 0))
        return box
    }

    @discardableResult
    private func command(_ box: TextAreaBox, _ selector: Selector) -> Bool {
        box.textView(box.textView, doCommandBy: selector)
    }

    func test_up_leavesFromTheStart_butMovesTheCaretMidText() {
        let box = box("line one\nline two", caret: 4)  // mid first line
        var left = 0
        box.onArrowUp = { left += 1 }

        XCTAssertFalse(command(box, #selector(NSResponder.moveUp(_:))), "mid-text Up moves the caret")
        XCTAssertEqual(left, 0)

        box.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(command(box, #selector(NSResponder.moveUp(_:))), "Up from the start leaves")
        XCTAssertEqual(left, 1)
    }

    func test_down_leavesFromTheEnd_butMovesTheCaretMidText() {
        let text = "line one\nline two"
        let box = box(text, caret: 4)  // mid text
        var left = 0
        box.onArrowDown = { left += 1 }

        XCTAssertFalse(command(box, #selector(NSResponder.moveDown(_:))), "mid-text Down moves the caret")
        XCTAssertEqual(left, 0)

        box.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        XCTAssertTrue(command(box, #selector(NSResponder.moveDown(_:))), "Down from the end leaves")
        XCTAssertEqual(left, 1)
    }

    func test_tab_leaves() {
        let box = box("anything", caret: 0)
        var tabbed = 0
        box.onTab = { tabbed += 1 }
        XCTAssertTrue(command(box, #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(tabbed, 1)
    }
}
