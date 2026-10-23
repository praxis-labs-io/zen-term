import XCTest

@testable import ZenTerm

final class SurfaceAttentionTests: XCTestCase {
    func test_waitingOutranksEverything() {
        XCTAssertGreaterThan(SurfaceAttention.waiting, .completed)
        XCTAssertGreaterThan(SurfaceAttention.completed, .working)
        XCTAssertGreaterThan(SurfaceAttention.working, .idle)
    }

    func test_rollupOfNothing_isIdle() {
        XCTAssertEqual(SurfaceAttention.rollup([]), .idle)
    }

    func test_rollup_takesTheLoudest_whateverTheOrder() {
        XCTAssertEqual(SurfaceAttention.rollup([.idle, .waiting, .working]), .waiting)
        XCTAssertEqual(SurfaceAttention.rollup([.waiting, .working, .idle]), .waiting)
        XCTAssertEqual(SurfaceAttention.rollup([.working, .idle]), .working)
    }

    func test_rollup_neverReplacesWaitingWithCompleted() {
        XCTAssertEqual(SurfaceAttention.rollup([.waiting, .completed]), .waiting)
        XCTAssertEqual(SurfaceAttention.rollup([.completed, .waiting]), .waiting)
    }

    func test_working_rendersAsNothing() {
        XCTAssertEqual(SurfaceAttention.working.tabState, .idle)
        XCTAssertEqual(SurfaceAttention.idle.tabState, .idle)
    }

    func test_theTwoColoredStates_keepTheirChip() {
        XCTAssertEqual(SurfaceAttention.completed.tabState, .completed)
        XCTAssertEqual(SurfaceAttention.waiting.tabState, .waiting)
    }
}
