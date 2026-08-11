import CoreGraphics
import XCTest

@testable import PaneKit

/// Micro-edge coverage for the pure pane layer: ratio extremes, `paneDiff` order
/// preservation, and spatial nav with partially-overlapping frames.
final class PaneKitEdgeCasesTests: XCTestCase {
    private func splitTree() -> PaneTree {
        PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
    }

    // MARK: settingRatio

    func test_settingRatio_storesExtremesVerbatim_pureLayerDoesNotClamp() {
        // The pure tree stores the ratio as-is: the pixel-minimum clamp lives in the caller, which
        // alone knows the rendered extent (see PaneTreeOps.edgeSplitID doc). This pins that contract
        // so a future "helpful" clamp in the pure layer is a conscious change, not a silent one.
        XCTAssertEqual(splitTree().settingRatio(SplitID(1), to: 0.0).ratio(of: SplitID(1)), 0.0)
        XCTAssertEqual(splitTree().settingRatio(SplitID(1), to: 1.0).ratio(of: SplitID(1)), 1.0)
        XCTAssertEqual(splitTree().settingRatio(SplitID(1), to: 2.5).ratio(of: SplitID(1)), 2.5)
    }

    func test_settingRatio_unknownSplit_isANoOp() {
        let tree = splitTree()
        XCTAssertEqual(tree.settingRatio(SplitID(999), to: 0.1).ratio(of: SplitID(1)), 0.5)
    }

    // MARK: paneDiff order preservation

    func test_paneDiff_preservesInputOrder() {
        let diff = paneDiff(from: [PaneID(3), PaneID(1), PaneID(2)], to: [PaneID(2), PaneID(1), PaneID(4)])
        XCTAssertEqual(diff.created, [PaneID(4)], "created follows the NEW list's order")
        XCTAssertEqual(diff.removed, [PaneID(3)], "removed follows the OLD list's order")
        XCTAssertEqual(diff.retained, [PaneID(2), PaneID(1)], "retained follows the NEW list's order, not sorted")
    }

    func test_paneDiff_emptyToNonEmpty_isAllCreated() {
        let diff = paneDiff(from: [], to: [PaneID(1), PaneID(2)])
        XCTAssertEqual(diff.created, [PaneID(1), PaneID(2)])
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.retained.isEmpty)
    }

    // MARK: spatial nav with partial overlap

    func test_nearestLeaf_findsPartiallyOverlappingNeighborBelow() {
        // B sits below A but is shifted right so the two only partially overlap in x. A downward
        // move from A must still land on B.
        let frames: [PaneID: CGRect] = [
            PaneID(1): CGRect(x: 0, y: 0, width: 100, height: 100),  // A
            PaneID(2): CGRect(x: 60, y: 120, width: 100, height: 100),  // B — overlaps A's x by 40pt
        ]
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: frames, direction: .down), PaneID(2))
        XCTAssertEqual(nearestLeaf(from: PaneID(2), frames: frames, direction: .up), PaneID(1))
    }

    func test_nearestLeaf_prefersTheMoreAlignedOfTwoCandidates() {
        // Both B and C lie below A; B overlaps A's column far more, so a downward move prefers it.
        let frames: [PaneID: CGRect] = [
            PaneID(1): CGRect(x: 0, y: 0, width: 100, height: 100),  // A
            PaneID(2): CGRect(x: 10, y: 120, width: 100, height: 100),  // B — near-aligned under A
            PaneID(3): CGRect(x: 400, y: 120, width: 100, height: 100),  // C — far to the right
        ]
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: frames, direction: .down), PaneID(2))
    }
}
