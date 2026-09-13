import AppKit
import XCTest

@testable import ZenTerm

final class ListPopoverTests: WindowTestCase {
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

    func test_openWithoutAWindowDoesNothing() {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let popover = ListPopover(anchor: anchor)

        popover.open(rows: [ListPopover.Row(view: NSView(), height: 28)])

        XCTAssertFalse(popover.isOpen)
    }
}
