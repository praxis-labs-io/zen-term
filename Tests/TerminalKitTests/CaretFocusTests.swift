import AppKit
import XCTest

@testable import TerminalKit

/// Only the first-responder pane may show a caret. SwiftTerm otherwise keeps a
/// caret on every pane, drawing a hollow outline (sometimes still blinking) when
/// the view isn't focused. `ProbeTerminalView` suppresses that by driving the
/// caret subview's `isHidden` from first-responder state.
final class CaretFocusTests: XCTestCase {
    private func caret(of view: NSView) -> NSView? {
        view.subviews.first { String(describing: type(of: $0)) == "CaretView" }
    }

    func test_caretHiddenUntilFocusedThenTracksFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let probe = ProbeTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(probe)

        guard let caret = caret(of: probe) else {
            return XCTFail("SwiftTerm caret subview not found")
        }

        // Enters the window unfocused → no caret.
        XCTAssertTrue(caret.isHidden)

        // Becomes first responder → caret shown.
        XCTAssertTrue(window.makeFirstResponder(probe))
        XCTAssertFalse(caret.isHidden)

        // Focus moves elsewhere → caret hidden again.
        XCTAssertTrue(window.makeFirstResponder(window.contentView))
        XCTAssertTrue(caret.isHidden)
    }
}
