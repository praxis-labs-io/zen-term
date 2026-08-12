import AppKit
import XCTest

@testable import ZenTerm

/// `ListPopover` is the card `Dropdown` and `CheckboxDropdown` both open. Their own suites drive it
/// through the real control; this one covers what only the popover can be asked directly.
final class ListPopoverTests: WindowTestCase {
    /// Each line is laid out at the height it was handed. The owners account for their own content
    /// height in Swift, so a dropped constraint leaves the card the right size with the rows inside
    /// it collapsed — right by the numbers, wrong on screen.
    func test_openLaysOutEachLineAtTheHeightItWasGiven() {
        let anchor = NSView(frame: NSRect(x: 20, y: 300, width: 220, height: 30))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(anchor)
        let popover = ListPopover(anchor: anchor)
        let header = NSView()
        let row = NSView()

        popover.open(rows: [
            ListPopover.Row(view: header, height: 20),
            ListPopover.Row(view: row, height: 28),
        ])

        XCTAssertEqual(header.frame.height, 20, "a group header collapsed instead of taking its height")
        XCTAssertEqual(row.frame.height, 28, "a row collapsed instead of taking its height")
    }

    /// Without a window there is nothing to parent the card to. Opening must be a no-op rather than
    /// leaving the owner believing a list is up.
    func test_openWithoutAWindowDoesNothing() {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let popover = ListPopover(anchor: anchor)

        popover.open(rows: [ListPopover.Row(view: NSView(), height: 28)])

        XCTAssertFalse(popover.isOpen)
    }
}
