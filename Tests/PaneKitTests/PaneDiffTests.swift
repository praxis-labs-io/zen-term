import XCTest
@testable import PaneKit

final class PaneDiffTests: XCTestCase {
    func test_split_addsOneCreated_retainsRest() {
        let d = paneDiff(from: [PaneID(1)], to: [PaneID(1), PaneID(2)])
        XCTAssertEqual(d.created, [PaneID(2)])
        XCTAssertEqual(d.removed, [])
        XCTAssertEqual(d.retained, [PaneID(1)])
    }
    func test_close_removesOne_retainsRest() {
        let d = paneDiff(from: [PaneID(1), PaneID(2)], to: [PaneID(1)])
        XCTAssertEqual(d.created, [])
        XCTAssertEqual(d.removed, [PaneID(2)])
        XCTAssertEqual(d.retained, [PaneID(1)])
    }
    func test_noChange_allRetained() {
        let d = paneDiff(from: [PaneID(1), PaneID(2)], to: [PaneID(1), PaneID(2)])
        XCTAssertEqual(d.created, [])
        XCTAssertEqual(d.removed, [])
        XCTAssertEqual(d.retained, [PaneID(1), PaneID(2)])
    }
}
