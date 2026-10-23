import XCTest

@testable import ZenTerm

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
