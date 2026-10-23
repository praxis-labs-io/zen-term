import AppKit
import XCTest

@testable import ZenTerm

final class HoverCardPlacementTests: XCTestCase {
    private func content(width: CGFloat, height: CGFloat = 600) -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    func test_cardCentersOnItsAnchorInsideTheMargins() {
        let frame = HoverCardView.placementFrame(
            size: NSSize(width: 100, height: 24),
            anchor: NSRect(x: 450, y: 300, width: 0, height: 0),
            in: content(width: 900), gap: 14)
        XCTAssertEqual(frame.midX, 450)
        XCTAssertEqual(frame.width, 100)
    }

    func test_aCardWiderThanTheWindowCapsInsteadOfOverflowing() {
        let frame = HoverCardView.placementFrame(
            size: NSSize(width: 500, height: 24),
            anchor: NSRect(x: 200, y: 300, width: 0, height: 0),
            in: content(width: 400), gap: 14)
        XCTAssertEqual(frame.minX, 8)
        XCTAssertEqual(frame.maxX, 392, "the card must end at the trailing margin, not past it")
    }

    func test_cardFlipsBelowTheAnchorAtTheTopEdge() {
        let host = content(width: 900, height: 600)
        let frame = HoverCardView.placementFrame(
            size: NSSize(width: 100, height: 24),
            anchor: NSRect(x: 450, y: 590, width: 0, height: 0),
            in: host, gap: 14)
        XCTAssertEqual(frame.maxY, 590 - 14, "the card must sit below an anchor at the top edge")
    }
}
