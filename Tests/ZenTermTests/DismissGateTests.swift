import XCTest

@testable import ZenTerm

/// The `DismissGate` latch behind every modal overlay's idempotent `animateOut` + click-through
/// `hitTest` (ZEN-94). A second `begin()` must be refused so a click during the exit spring can't
/// double-run the animation, and `isDismissing` must latch so `hitTest` stops intercepting.
final class DismissGateTests: XCTestCase {
    func test_firstBeginProceeds_secondIsRefused() {
        var gate = DismissGate()
        XCTAssertFalse(gate.isDismissing)
        XCTAssertTrue(gate.begin(), "the first dismissal proceeds")
        XCTAssertTrue(gate.isDismissing, "and latches so hitTest falls through")
        XCTAssertFalse(gate.begin(), "a second dismissal is ignored (idempotent)")
        XCTAssertFalse(gate.begin())
    }
}
