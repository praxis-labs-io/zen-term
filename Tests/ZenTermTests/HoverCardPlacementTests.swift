import AppKit
import XCTest

@testable import ZenTerm

/// The shared hover-card placement math (`ChromeTooltip` and `LinkPreviewView` both sit on it).
/// Pure geometry, so it is tested as values; where a card lands on screen stays the runbook's.
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

    /// The review's inversion case: a card wider than the window made the clamp's bounds cross,
    /// pinning x to the leading margin and running the card off the trailing edge — clipping
    /// exactly the tail a middle-truncated URL preserves. The width has to cap first.
    func test_aCardWiderThanTheWindowCapsInsteadOfOverflowing() {
        let frame = HoverCardView.placementFrame(
            size: NSSize(width: 500, height: 24),
            anchor: NSRect(x: 200, y: 300, width: 0, height: 0),
            in: content(width: 400), gap: 14)
        XCTAssertEqual(frame.minX, 8)
        XCTAssertEqual(frame.maxX, 392, "the card must end at the trailing margin, not past it")
    }

    /// An anchor near the visual top edge flips the card below so it never clips.
    func test_cardFlipsBelowTheAnchorAtTheTopEdge() {
        let host = content(width: 900, height: 600)  // unflipped: visual top is maxY
        let frame = HoverCardView.placementFrame(
            size: NSSize(width: 100, height: 24),
            anchor: NSRect(x: 450, y: 590, width: 0, height: 0),
            in: host, gap: 14)
        XCTAssertEqual(frame.maxY, 590 - 14, "the card must sit below an anchor at the top edge")
    }
}
