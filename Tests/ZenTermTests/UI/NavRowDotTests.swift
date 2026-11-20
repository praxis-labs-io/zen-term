import AppKit
import XCTest

@testable import ZenTerm

final class NavRowDotTests: XCTestCase {
    func test_aDot_joinsTheAccessoriesAndSaysItsState() throws {
        let row = NavRow(title: "zen-term") {}
        row.setDetail("main")

        row.setDot(.done)

        XCTAssertEqual(try XCTUnwrap(row.dotForTesting).state, .done)
        XCTAssertEqual(row.accessibilityValue() as? String, "main, \(StateDot.State.done.accessibilityValue)")
    }

    func test_noState_hidesTheDotAndItsValue() {
        let row = NavRow(title: "zen-term") {}
        row.setDot(.blocked)

        row.setDot(nil)

        XCTAssertNil(row.dotForTesting)
        XCTAssertNil(row.accessibilityValue())
    }
}
