import XCTest
import CoreGraphics
@testable import PaneKit

final class SpatialNavTests: XCTestCase {
    // Layout:  A | B   (side by side), C beneath A.
    //  A = (0,0,100,100)   B = (110,0,100,100)   C = (0,110,100,100)
    private let frames: [PaneID: CGRect] = [
        PaneID(1): CGRect(x: 0,   y: 0,   width: 100, height: 100), // A
        PaneID(2): CGRect(x: 110, y: 0,   width: 100, height: 100), // B
        PaneID(3): CGRect(x: 0,   y: 110, width: 100, height: 100), // C
    ]

    func test_right_fromA_findsB() {
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: frames, direction: .right), PaneID(2))
    }
    func test_left_fromB_findsA() {
        XCTAssertEqual(nearestLeaf(from: PaneID(2), frames: frames, direction: .left), PaneID(1))
    }
    func test_down_fromA_findsC() {
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: frames, direction: .down), PaneID(3))
    }
    func test_up_fromA_findsNothing() {
        XCTAssertNil(nearestLeaf(from: PaneID(1), frames: frames, direction: .up))
    }
    func test_right_fromB_findsNothing() {
        XCTAssertNil(nearestLeaf(from: PaneID(2), frames: frames, direction: .right))
    }
    func test_unknownSource_returnsNil() {
        XCTAssertNil(nearestLeaf(from: PaneID(99), frames: frames, direction: .left))
    }
    func test_tie_isBrokenByLowerPaneID_deterministically() {
        // Panes 2 and 3 are both to the right of 1 with identical score
        // (dx=200, |dy|=60). The lower PaneID.raw (2) must win regardless of
        // dictionary iteration order.
        let f: [PaneID: CGRect] = [
            PaneID(1): CGRect(x: 0,   y: 0,   width: 100, height: 100),
            PaneID(2): CGRect(x: 200, y: -60, width: 100, height: 100),
            PaneID(3): CGRect(x: 200, y: 60,  width: 100, height: 100),
        ]
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: f, direction: .right), PaneID(2))
    }
}
