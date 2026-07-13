import CoreGraphics
import XCTest

@testable import PaneKit

final class SpatialNavTests: XCTestCase {
    // Layout:  A | B   (side by side), C beneath A.
    //  A = (0,0,100,100)   B = (110,0,100,100)   C = (0,110,100,100)
    private let frames: [PaneID: CGRect] = [
        PaneID(1): CGRect(x: 0, y: 0, width: 100, height: 100),  // A
        PaneID(2): CGRect(x: 110, y: 0, width: 100, height: 100),  // B
        PaneID(3): CGRect(x: 0, y: 110, width: 100, height: 100),  // C
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
    // Drawer-style layout for the direction predicate: canvas upper-left, bottom
    // drawer beneath it (canvas column only), right drawer full height. The right
    // drawer is *diagonal* to both the canvas (vertically) and the bottom drawer —
    // its center offset points up/down at them, but they share no horizontal range.
    //  canvas = (0,0,700,700)   bottom = (0,710,700,290)   right = (710,0,290,1000)
    private let canvas = PaneID(1)
    private let bottom = PaneID(2)
    private let right = PaneID(3)
    private var drawerFrames: [PaneID: CGRect] {
        [
            canvas: CGRect(x: 0, y: 0, width: 700, height: 700),
            bottom: CGRect(x: 0, y: 710, width: 700, height: 290),
            right: CGRect(x: 710, y: 0, width: 290, height: 1000),
        ]
    }

    func test_nearest_down_fromRightDrawer_findsNothing() {
        // The bottom drawer is diagonal (down-left) from the full-height right drawer,
        // not below it — vertical nav out of the right drawer must be a no-op.
        XCTAssertNil(nearestLeaf(from: right, frames: drawerFrames, direction: .down))
    }
    func test_nearest_up_fromRightDrawer_findsNothing() {
        XCTAssertNil(nearestLeaf(from: right, frames: drawerFrames, direction: .up))
    }
    func test_nearest_left_fromRightDrawer_findsCanvas() {
        // Both the canvas and the bottom drawer lie left; the canvas is the straighter hop.
        XCTAssertEqual(nearestLeaf(from: right, frames: drawerFrames, direction: .left), canvas)
    }
    func test_nearest_right_fromBottom_findsRightDrawer() {
        // The full-height right drawer overlaps the bottom drawer's y-range, so a
        // horizontal hop between them stays legal.
        XCTAssertEqual(nearestLeaf(from: bottom, frames: drawerFrames, direction: .right), right)
    }
    func test_nearest_up_fromBottom_findsCanvas_notDiagonalRightDrawer() {
        XCTAssertEqual(nearestLeaf(from: bottom, frames: drawerFrames, direction: .up), canvas)
    }

    func test_lies_up_fromBottom_rejectsDiagonalRightDrawer() {
        XCTAssertFalse(lies(right, inDirection: .up, from: bottom, frames: drawerFrames))
    }
    func test_lies_up_fromBottom_acceptsCanvasAbove() {
        XCTAssertTrue(lies(canvas, inDirection: .up, from: bottom, frames: drawerFrames))
    }
    func test_lies_down_fromCanvas_rejectsDiagonalRightDrawer() {
        XCTAssertFalse(lies(right, inDirection: .down, from: canvas, frames: drawerFrames))
    }
    func test_lies_down_fromCanvas_acceptsBottomDrawer() {
        XCTAssertTrue(lies(bottom, inDirection: .down, from: canvas, frames: drawerFrames))
    }
    func test_lies_right_fromCanvas_acceptsRightDrawer() {
        XCTAssertTrue(lies(right, inDirection: .right, from: canvas, frames: drawerFrames))
    }
    func test_lies_up_fromBottom_acceptsRightHalfPane() {
        // The designed return-hop case: a right-half pane over the bottom drawer shares
        // the drawer's x-range, so the memory may still send focus back to it even
        // though the geometric scorer would pick the (nearer-centered) left pane.
        var f = drawerFrames
        f[canvas] = CGRect(x: 0, y: 0, width: 340, height: 700)
        let rightHalfPane = PaneID(4)
        f[rightHalfPane] = CGRect(x: 360, y: 0, width: 340, height: 700)
        XCTAssertTrue(lies(rightHalfPane, inDirection: .up, from: bottom, frames: f))
    }
    func test_lies_missingFrames_returnsFalse() {
        XCTAssertFalse(lies(PaneID(99), inDirection: .up, from: bottom, frames: drawerFrames))
        XCTAssertFalse(lies(right, inDirection: .up, from: PaneID(99), frames: drawerFrames))
    }

    func test_tie_isBrokenByLowerPaneID_deterministically() {
        // Panes 2 and 3 are both to the right of 1 with identical score
        // (dx=200, |dy|=60). The lower PaneID.raw (2) must win regardless of
        // dictionary iteration order.
        let f: [PaneID: CGRect] = [
            PaneID(1): CGRect(x: 0, y: 0, width: 100, height: 100),
            PaneID(2): CGRect(x: 200, y: -60, width: 100, height: 100),
            PaneID(3): CGRect(x: 200, y: 60, width: 100, height: 100),
        ]
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: f, direction: .right), PaneID(2))
    }
}
