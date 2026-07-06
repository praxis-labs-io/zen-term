import XCTest
@testable import PaneKit

final class PaneTreeOpsTests: XCTestCase {
    func test_paneIDEquatable() {
        XCTAssertEqual(PaneID(1), PaneID(1))
        XCTAssertNotEqual(PaneID(1), PaneID(2))
    }

    func test_leafIDs_and_firstLeaf() {
        let tree = PaneNode.split(
            id: SplitID(1), axis: .vertical, ratio: 0.5,
            a: .leaf(PaneID(10)),
            b: .split(id: SplitID(2), axis: .horizontal, ratio: 0.5,
                      a: .leaf(PaneID(20)), b: .leaf(PaneID(30)))
        )
        XCTAssertEqual(tree.leafIDs, [PaneID(10), PaneID(20), PaneID(30)])
        XCTAssertEqual(tree.firstLeaf, PaneID(10))
        XCTAssertTrue(tree.contains(PaneID(30)))
        XCTAssertFalse(tree.contains(PaneID(99)))
    }
}
