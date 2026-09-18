import TabKit
import XCTest

@testable import ZenTerm

final class AttentionStoreTests: XCTestCase {
    private let tab = TabID(1)
    private let other = TabID(2)

    private func makeStore(now: Date = Date(timeIntervalSince1970: 0)) -> AttentionStore {
        AttentionStore(now: { now })
    }

    func test_anUnseenLatch_colorsItsTab() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .waiting, seen: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_aSeenLatch_colorsNothing() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .waiting, seen: true)

        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_completionNeverReplacesWaiting_onOneSurface() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .waiting, seen: false)
        store.record(pane, .completed, seen: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_waitingOverridesAnEarlierCompletion() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .completed, seen: false)
        store.record(pane, .waiting, seen: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_aTabTakesTheLoudestOfItsSurfaces() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        let drawer = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.register(drawer, tab: tab)

        store.record(pane, .completed, seen: false)
        store.record(drawer, .waiting, seen: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
        XCTAssertEqual(store.state(of: pane), .completed)
        XCTAssertEqual(store.state(of: drawer), .waiting)
    }

    func test_anEventSeenOnScreen_isNotRevivedByALaterOneOffScreen() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: true)

        store.record(pane, .completed, seen: false)

        XCTAssertEqual(store.state(tab: tab), .completed)
    }

    func test_answeringATab_clearsEverySurfaceInIt() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        let drawer = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.register(drawer, tab: tab)
        store.record(pane, .waiting, seen: false)
        store.record(drawer, .completed, seen: false)

        store.markSeen(tab: tab)

        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_aLaterEventAfterAnAnswer_colorsTheTabAgain() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)
        store.markSeen(tab: tab)

        store.record(pane, .waiting, seen: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_releasingAnUnseenSurface_leavesItsTabColored() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)

        store.release(pane)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_releasingASeenSurface_leavesNothingBehind() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: true)

        store.release(pane)

        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_visitingATab_clearsAResidualLeftByAClosedPane() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)
        store.release(pane)

        store.visit(tab) { _ in true }

        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_visitingATab_leavesWhatIsOffScreenLatched() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        let drawer = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.register(drawer, tab: tab)
        store.record(pane, .completed, seen: false)
        store.record(drawer, .waiting, seen: false)

        store.visit(tab) { $0 == pane }

        XCTAssertEqual(store.state(of: pane), .idle)
        XCTAssertEqual(store.state(of: drawer), .waiting)
    }

    func test_working_risesAndFallsWithProgress() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.setWorking(pane, true)
        XCTAssertEqual(store.state(tab: tab), .working)

        store.setWorking(pane, false)
        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_working_neverMasksAWaitingLatch() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)

        store.setWorking(pane, true)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_aWindowScopedFloat_reachesTheWindowButNoTab() {
        let store = makeStore()
        let float = SurfaceIDs.mint()
        store.register(float, tab: nil)

        store.record(float, .waiting, seen: false)

        XCTAssertEqual(store.state(tab: tab), .idle)
        XCTAssertEqual(store.windowState, .waiting)
    }

    func test_theWindowTakesTheLoudestTab() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        let b = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.register(b, tab: other)

        store.record(a, .completed, seen: false)
        store.record(b, .waiting, seen: false)

        XCTAssertEqual(store.windowState, .waiting)
    }

    func test_closingATab_takesItOutOfTheWindow() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)

        store.dropTab(tab)

        XCTAssertEqual(store.windowState, .idle)
    }

    func test_waitingSince_isWhenTheOldestThingStartedAsking() {
        let start = Date(timeIntervalSince1970: 1000)
        let store = AttentionStore(now: { start })
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        XCTAssertNil(store.waitingSince)
        store.record(pane, .waiting, seen: false)
        XCTAssertEqual(store.waitingSince, start)

        store.markSeen(tab: tab)
        XCTAssertNil(store.waitingSince)
    }

    func test_waitingSince_survivesTheSurfaceThatRaisedIt() {
        let start = Date(timeIntervalSince1970: 2000)
        let store = AttentionStore(now: { start })
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)

        store.release(pane)

        XCTAssertEqual(store.waitingSince, start)
    }
}
