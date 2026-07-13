import PaneKit
import XCTest

@testable import ZenTerm

/// Covers `TabController.navReturnPruned` — the pure transform behind pruning directional focus
/// memory when panes close (ZEN-58). Correctness tolerates stale entries, so this guards the
/// memory-hygiene contract: a closed pane leaves no trace as either an origin or a target.
final class NavReturnPruneTests: XCTestCase {
    private let a = PaneID(1)
    private let b = PaneID(2)
    private let c = PaneID(3)

    func test_dropsClosedPaneAsBothOriginAndTarget() {
        // Closing a drops a's own entry AND b's `.right → a` entry (a dead target); b is then
        // empty, so it's dropped too.
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b], b: [.right: a]]
        let pruned = TabController.navReturnPruned(map, removing: [a])
        XCTAssertEqual(pruned, [:])
    }

    func test_keepsUnaffectedOrigin() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b], c: [.up: b]]
        let pruned = TabController.navReturnPruned(map, removing: [a])
        XCTAssertNil(pruned[a])
        XCTAssertEqual(pruned[c], [.up: b])  // c is untouched by closing a
    }

    func test_dropsClosedPaneAsRememberedTarget() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b, .up: c]]
        let pruned = TabController.navReturnPruned(map, removing: [b])
        XCTAssertEqual(pruned[a], [.up: c])  // the .left → b entry is gone, .up → c survives
    }

    func test_dropsOriginLeftWithNoDirections() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b]]
        let pruned = TabController.navReturnPruned(map, removing: [b])
        XCTAssertTrue(pruned.isEmpty)  // a's only entry pointed at b — a is dropped, not left as [:]
    }

    func test_closingMultiplePanesAtOnce() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b], b: [.right: c], c: [.up: a]]
        let pruned = TabController.navReturnPruned(map, removing: [a, b])
        XCTAssertEqual(pruned, [:])  // c's only entry pointed at a (closed) → c dropped too
    }

    func test_noRemovalsIsIdentity() {
        let map: [PaneID: [Direction: PaneID]] = [a: [.left: b], b: [.right: a]]
        XCTAssertEqual(TabController.navReturnPruned(map, removing: []), map)
    }
}
