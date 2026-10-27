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

    func test_openCard_takesTheOverlayTier() {
        let anchor = NSView(frame: NSRect(x: 20, y: 300, width: 220, height: 30))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(anchor)
        let popover = ListPopover(anchor: anchor)

        popover.open(rows: [ListPopover.Row(view: NSView(), height: 28)])
        window.displayIfNeeded()

        let card = popover.cardForTesting
        XCTAssertEqual(CGFloat(card?.layer?.shadowRadius ?? -1), FloatShadow.Tier.overlay.blur)
        XCTAssertEqual(card?.layer?.backgroundColor, CardChrome.fill.cgColor)
        XCTAssertEqual(card?.layer?.borderColor, FloatShadow.edge.cgColor)
    }

    func test_openWithoutAWindowDoesNothing() {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let popover = ListPopover(anchor: anchor)

        popover.open(rows: [ListPopover.Row(view: NSView(), height: 28)])

        XCTAssertFalse(popover.isOpen)
    }

    func test_openContent_sizesToTheContentPastTheRowsCap_insideTheCardInsets() throws {
        let (popover, _, _) = contentPopover(windowHeight: 900, contentSize: NSSize(width: 284, height: 500))

        let card = try XCTUnwrap(popover.cardForTesting)

        XCTAssertEqual(card.frame.width, 284 + ChromeMetrics.Spacing.s8 * 2, accuracy: 0.5)
        XCTAssertEqual(card.frame.height, 500 + ChromeMetrics.Spacing.s6 * 2, accuracy: 0.5)
        XCTAssertGreaterThan(card.frame.height, 260, "content mode is not held to the rows cap")
    }

    func test_openContent_inAShortWindow_clampsToTheWindowAndAddsTheScrollerLane() throws {
        let (tall, _, _) = contentPopover(windowHeight: 900, contentSize: NSSize(width: 284, height: 500))
        let (short, window, content) = contentPopover(windowHeight: 300, contentSize: NSSize(width: 284, height: 500))
        let roomy = try XCTUnwrap(tall.cardForTesting)
        let clamped = try XCTUnwrap(short.cardForTesting)

        XCTAssertEqual(
            clamped.frame.height, window.contentView!.bounds.height - ChromeMetrics.Spacing.s8 * 2, accuracy: 0.5)
        XCTAssertEqual(clamped.frame.width - roomy.frame.width, ChromeMetrics.Spacing.s16, accuracy: 0.5)
        clamped.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            content.convert(content.bounds, to: clamped).maxX,
            clamped.frame.width - ChromeMetrics.Spacing.s16 - ChromeMetrics.Spacing.s8 + 0.5,
            "content runs into the scroller lane")
    }

    private func contentPopover(windowHeight: CGFloat, contentSize: NSSize) -> (ListPopover, NSWindow, NSView) {
        let anchor = NSView(frame: NSRect(x: 20, y: windowHeight - 100, width: 220, height: 30))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: windowHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(anchor)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: contentSize.width).isActive = true
        content.heightAnchor.constraint(equalToConstant: contentSize.height).isActive = true
        let popover = ListPopover(anchor: anchor)
        popover.open(content: content)
        return (popover, window, content)
    }
}
