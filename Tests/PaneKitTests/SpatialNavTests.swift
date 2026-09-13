import CoreGraphics
import XCTest

@testable import PaneKit

final class SpatialNavTests: XCTestCase {
    private let frames: [PaneID: CGRect] = [
        PaneID(1): CGRect(x: 0, y: 0, width: 100, height: 100),
        PaneID(2): CGRect(x: 110, y: 0, width: 100, height: 100),
        PaneID(3): CGRect(x: 0, y: 110, width: 100, height: 100),
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
        XCTAssertNil(nearestLeaf(from: right, frames: drawerFrames, direction: .down))
    }
    func test_nearest_up_fromRightDrawer_findsNothing() {
        XCTAssertNil(nearestLeaf(from: right, frames: drawerFrames, direction: .up))
    }
    func test_nearest_left_fromRightDrawer_findsCanvas() {
        XCTAssertEqual(nearestLeaf(from: right, frames: drawerFrames, direction: .left), canvas)
    }
    func test_nearest_right_fromBottom_findsRightDrawer() {
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
        let f: [PaneID: CGRect] = [
            PaneID(1): CGRect(x: 0, y: 0, width: 100, height: 100),
            PaneID(2): CGRect(x: 200, y: -60, width: 100, height: 100),
            PaneID(3): CGRect(x: 200, y: 60, width: 100, height: 100),
        ]
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: f, direction: .right), PaneID(2))
    }
}
