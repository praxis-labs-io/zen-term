import PaneKit
import XCTest

@testable import ZenTerm

final class NavReturnPruneTests: XCTestCase {
    private let a = PaneID(1)
    private let b = PaneID(2)
    private let c = PaneID(3)

    func test_dropsClosedPaneAsBothOriginAndTarget() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b], b: [.right: a]]
        let pruned = TabController.navReturnPruned(map, removing: [a])
        XCTAssertEqual(pruned, [:])
    }

    func test_keepsUnaffectedOrigin() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b], c: [.up: b]]
        let pruned = TabController.navReturnPruned(map, removing: [a])
        XCTAssertNil(pruned[a])
        XCTAssertEqual(pruned[c], [.up: b])
    }

    func test_dropsClosedPaneAsRememberedTarget() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b, .up: c]]
        let pruned = TabController.navReturnPruned(map, removing: [b])
        XCTAssertEqual(pruned[a], [.up: c])
    }

    func test_dropsOriginLeftWithNoDirections() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b]]
        let pruned = TabController.navReturnPruned(map, removing: [b])
        XCTAssertTrue(pruned.isEmpty)
    }

    func test_closingMultiplePanesAtOnce() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b], b: [.right: c], c: [.up: a]]
        let pruned = TabController.navReturnPruned(map, removing: [a, b])
        XCTAssertEqual(pruned, [:])
    }

    func test_noRemovalsIsIdentity() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b], b: [.right: a]]
        XCTAssertEqual(TabController.navReturnPruned(map, removing: []), map)
    }
}
