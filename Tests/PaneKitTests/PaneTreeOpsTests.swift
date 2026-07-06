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

    func test_splitting_replacesLeafWithSplit_focusMovesToNew() {
        let tree = PaneTree(singleLeaf: PaneID(1))
        let out = tree.splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        XCTAssertEqual(out.leafIDs, [PaneID(1), PaneID(2)])
        XCTAssertEqual(out.focusedLeaf, PaneID(2))
        guard case let .split(id, axis, ratio, a, b) = out.root else { return XCTFail("expected split") }
        XCTAssertEqual(id, SplitID(1)); XCTAssertEqual(axis, .vertical); XCTAssertEqual(ratio, 0.5)
        XCTAssertEqual(a.firstLeaf, PaneID(1)); XCTAssertEqual(b.firstLeaf, PaneID(2))
    }

    func test_splitting_absentLeaf_returnsUnchanged() {
        let tree = PaneTree(singleLeaf: PaneID(1))
        let out = tree.splitting(PaneID(99), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        XCTAssertEqual(out.leafIDs, [PaneID(1)])
    }

    func test_closing_promotesSibling_andCollapsesSplit() {
        // (1 | 2), focus 2 → close 2 → just leaf 1, focus 1.
        let split = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        let out = split.closing(PaneID(2))
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.leafIDs, [PaneID(1)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(1))
        if case .leaf = out!.root {} else { XCTFail("expected the sibling promoted to root leaf") }
    }

    func test_closing_deepSibling_keepsOtherPanes() {
        // 1 | (2 / 3): close 2 → 1 | 3, focus 3 (sibling firstLeaf).
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
            .splitting(PaneID(2), axis: .horizontal, newLeaf: PaneID(3), newSplit: SplitID(2))
        let out = tree.closing(PaneID(2))
        XCTAssertEqual(out?.leafIDs, [PaneID(1), PaneID(3)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(3))
    }

    func test_closing_lastLeaf_returnsNil() {
        XCTAssertNil(PaneTree(singleLeaf: PaneID(1)).closing(PaneID(1)))
    }

    func test_closing_unfocusedLeaf_keepsFocusIfStillPresent() {
        // 1 | 2, focus 1, close 2 → leaf 1, focus stays 1.
        var tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        tree.focusedLeaf = PaneID(1)
        let out = tree.closing(PaneID(2))
        XCTAssertEqual(out?.focusedLeaf, PaneID(1))
    }

    func test_settingRatio() {
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        let out = tree.settingRatio(SplitID(1), to: 0.3)
        guard case let .split(_, _, ratio, _, _) = out.root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.3)
    }

    func test_closing_focusedLeaf_promotesSiblingSubtree_toFirstLeaf() {
        // 1 | (2 | 3): focus 1 (its sibling is the (2|3) split), close 1 →
        // the (2|3) subtree is promoted; focus lands on its firstLeaf = 2.
        var tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(10))
            .splitting(PaneID(2), axis: .vertical, newLeaf: PaneID(3), newSplit: SplitID(11))
        tree.focusedLeaf = PaneID(1)
        let out = tree.closing(PaneID(1))
        XCTAssertEqual(out?.leafIDs, [PaneID(2), PaneID(3)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(2))
    }

    func test_closing_focusedDeepLeaf_forwardsPromotionThroughAncestor() {
        // 1 | (2 | 3): focus 3, close the focused leaf 3 → its sibling 2 is promoted,
        // and promotedFocus must forward up through the root split. Focus → 2.
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(10))
            .splitting(PaneID(2), axis: .vertical, newLeaf: PaneID(3), newSplit: SplitID(11))
        XCTAssertEqual(tree.focusedLeaf, PaneID(3))
        let out = tree.closing(PaneID(3))
        XCTAssertEqual(out?.leafIDs, [PaneID(1), PaneID(2)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(2))
    }
}
