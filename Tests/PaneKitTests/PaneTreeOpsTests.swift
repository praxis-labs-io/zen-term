import XCTest
@testable import PaneKit

final class PaneTreeOpsTests: XCTestCase {
    func test_paneIDEquatable() {
        XCTAssertEqual(PaneID(1), PaneID(1))
        XCTAssertNotEqual(PaneID(1), PaneID(2))
    }
}
