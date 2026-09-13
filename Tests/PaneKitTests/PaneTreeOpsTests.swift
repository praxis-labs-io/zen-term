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
            b: .split(
                id: SplitID(2), axis: .horizontal, ratio: 0.5,
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
        guard case .split(let id, let axis, let ratio, let a, let b) = out.root else {
            return XCTFail("expected split")
        }
        XCTAssertEqual(id, SplitID(1)); XCTAssertEqual(axis, .vertical); XCTAssertEqual(ratio, 0.5)
        XCTAssertEqual(a.firstLeaf, PaneID(1)); XCTAssertEqual(b.firstLeaf, PaneID(2))
    }

    func test_splitting_absentLeaf_returnsUnchanged() {
        let tree = PaneTree(singleLeaf: PaneID(1))
        let out = tree.splitting(PaneID(99), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        XCTAssertEqual(out.leafIDs, [PaneID(1)])
    }

    func test_closing_promotesSibling_andCollapsesSplit() {
        let split = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        let out = split.closing(PaneID(2))
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.leafIDs, [PaneID(1)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(1))
        if case .leaf = out!.root {} else { XCTFail("expected the sibling promoted to root leaf") }
    }

    func test_closing_deepSibling_keepsOtherPanes() {
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
        guard case .split(_, _, let ratio, _, _) = out.root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.3)
    }

    func test_edgeSplitID_sharedDivider_sameSplit_regardlessOfFocus() {
        var tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        tree.focusedLeaf = PaneID(1)
        XCTAssertEqual(tree.edgeSplitID(for: PaneID(1), axis: .vertical, positive: true), SplitID(1))
        XCTAssertEqual(tree.edgeSplitID(for: PaneID(1), axis: .vertical, positive: false), SplitID(1))
        tree.focusedLeaf = PaneID(2)
        XCTAssertEqual(tree.edgeSplitID(for: PaneID(2), axis: .vertical, positive: true), SplitID(1))
        XCTAssertEqual(tree.edgeSplitID(for: PaneID(2), axis: .vertical, positive: false), SplitID(1))
    }

    func test_edgeSplitID_edgePane_resolvesFromEitherKey() {
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        XCTAssertEqual(tree.focusedLeaf, PaneID(2))
        XCTAssertNotNil(tree.edgeSplitID(for: PaneID(2), axis: .vertical, positive: true))
        XCTAssertNotNil(tree.edgeSplitID(for: PaneID(2), axis: .vertical, positive: false))
    }

    func test_edgeSplitID_noSplitOnAxis_returnsNil() {
        let single = PaneTree(singleLeaf: PaneID(1))
        XCTAssertNil(single.edgeSplitID(for: PaneID(1), axis: .vertical, positive: true))
        let vertical = single.splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        XCTAssertNil(vertical.edgeSplitID(for: PaneID(2), axis: .horizontal, positive: true), "no horizontal split")
    }

    func test_edgeSplitID_absentLeaf_returnsNil() {
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        XCTAssertNil(tree.edgeSplitID(for: PaneID(99), axis: .vertical, positive: true))
    }

    func test_edgeSplitID_horizontalStack_resolvesSharedDivider() {
        var tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .horizontal, newLeaf: PaneID(2), newSplit: SplitID(1))
        tree.focusedLeaf = PaneID(2)
        XCTAssertEqual(tree.edgeSplitID(for: PaneID(2), axis: .horizontal, positive: true), SplitID(1))
        XCTAssertEqual(tree.edgeSplitID(for: PaneID(2), axis: .horizontal, positive: false), SplitID(1))
    }

    func test_edgeSplitID_nested_picksNearestSplit() {
        var tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(10))
            .splitting(PaneID(2), axis: .vertical, newLeaf: PaneID(3), newSplit: SplitID(11))
        tree.focusedLeaf = PaneID(2)
        XCTAssertEqual(
            tree.edgeSplitID(for: PaneID(2), axis: .vertical, positive: true), SplitID(11),
            "grows into 3 via inner split")
    }

    func test_ratioOf_readsSplitRatio() {
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
            .settingRatio(SplitID(1), to: 0.3)
        XCTAssertEqual(tree.ratio(of: SplitID(1)), 0.3)
        XCTAssertNil(tree.ratio(of: SplitID(99)))
    }

    func test_closing_focusedLeaf_promotesSiblingSubtree_toFirstLeaf() {
        var tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(10))
            .splitting(PaneID(2), axis: .vertical, newLeaf: PaneID(3), newSplit: SplitID(11))
        tree.focusedLeaf = PaneID(1)
        let out = tree.closing(PaneID(1))
        XCTAssertEqual(out?.leafIDs, [PaneID(2), PaneID(3)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(2))
    }

    func test_closing_focusedDeepLeaf_forwardsPromotionThroughAncestor() {
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(10))
            .splitting(PaneID(2), axis: .vertical, newLeaf: PaneID(3), newSplit: SplitID(11))
        XCTAssertEqual(tree.focusedLeaf, PaneID(3))
        let out = tree.closing(PaneID(3))
        XCTAssertEqual(out?.leafIDs, [PaneID(1), PaneID(2)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(2))
    }
}
