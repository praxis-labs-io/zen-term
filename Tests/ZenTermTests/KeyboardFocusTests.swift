import XCTest

@testable import ZenTerm

final class KeyboardFocusTests: XCTestCase {
    func test_step_movesAndClampsAtEnds() {
        XCTAssertEqual(KeyboardFocus.step(from: 0, delta: 1, count: 3), 1)
        XCTAssertEqual(KeyboardFocus.step(from: 2, delta: 1, count: 3), nil)  // clamp at end
        XCTAssertEqual(KeyboardFocus.step(from: 0, delta: -1, count: 3), nil)  // clamp at start
        XCTAssertEqual(KeyboardFocus.step(from: 1, delta: -1, count: 3), 0)
    }

    func test_step_noAnchor_jumpsToEnd() {
        XCTAssertEqual(KeyboardFocus.step(from: nil, delta: 1, count: 3), 0)  // first
        XCTAssertEqual(KeyboardFocus.step(from: nil, delta: -1, count: 3), 2)  // last
    }

    func test_step_emptyStops_isNil() {
        XCTAssertNil(KeyboardFocus.step(from: nil, delta: 1, count: 0))
    }
}
