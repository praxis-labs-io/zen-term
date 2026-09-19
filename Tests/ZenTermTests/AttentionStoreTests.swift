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

        store.record(pane, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_aSeenLatch_colorsNothing() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .waiting, seen: true, focused: false)

        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_completionNeverReplacesWaiting_onOneSurface() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .waiting, seen: false, focused: false)
        store.record(pane, .completed, seen: false, focused: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_waitingOverridesAnEarlierCompletion() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .completed, seen: false, focused: false)
        store.record(pane, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_aTabTakesTheLoudestOfItsSurfaces() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        let drawer = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.register(drawer, tab: tab)

        store.record(pane, .completed, seen: false, focused: false)
        store.record(drawer, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
        XCTAssertEqual(store.state(of: pane), .completed)
        XCTAssertEqual(store.state(of: drawer), .waiting)
    }

    func test_anEventSeenOnScreen_isNotRevivedByALaterOneOffScreen() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: true, focused: false)

        store.record(pane, .completed, seen: false, focused: false)

        XCTAssertEqual(store.state(tab: tab), .completed)
    }

    func test_answeringATab_clearsEverySurfaceInIt() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        let drawer = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.register(drawer, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)
        store.record(drawer, .completed, seen: false, focused: false)

        store.markSeen(tab: tab)

        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_aLaterEventAfterAnAnswer_colorsTheTabAgain() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)
        store.markSeen(tab: tab)

        store.record(pane, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_releasingAnUnseenSurface_leavesItsTabColored() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)

        store.release(pane)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_releasingASeenSurface_leavesNothingBehind() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: true, focused: false)

        store.release(pane)

        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_visitingATab_clearsAResidualLeftByAClosedPane() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)
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
        store.record(pane, .completed, seen: false, focused: false)
        store.record(drawer, .waiting, seen: false, focused: false)

        store.visit(tab) { $0 == pane }

        XCTAssertEqual(store.state(of: pane), .idle)
        XCTAssertEqual(store.state(of: drawer), .waiting)
    }

    func test_working_risesAndFallsWithProgress() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.setWorking(pane, true, focused: false)
        XCTAssertEqual(store.state(tab: tab), .working)

        store.setWorking(pane, false, focused: false)
        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_working_neverMasksAWaitingLatch() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)

        store.setWorking(pane, true, focused: false)

        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_aWindowScopedFloat_reachesTheWindowButNoTab() {
        let store = makeStore()
        let float = SurfaceIDs.mint()
        store.register(float, tab: nil)

        store.record(float, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.state(tab: tab), .idle)
        XCTAssertEqual(store.windowState, .waiting)
    }

    func test_theWindowTakesTheLoudestTab() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        let b = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.register(b, tab: other)

        store.record(a, .completed, seen: false, focused: false)
        store.record(b, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.windowState, .waiting)
    }

    func test_closingATab_takesItOutOfTheWindow() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)

        store.dropTab(tab)

        XCTAssertEqual(store.windowState, .idle)
    }

    func test_waitingSince_isWhenTheOldestThingStartedAsking() {
        let start = Date(timeIntervalSince1970: 1000)
        let store = AttentionStore(now: { start })
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        XCTAssertNil(store.waitingSince)
        store.record(pane, .waiting, seen: false, focused: false)
        XCTAssertEqual(store.waitingSince, start)

        store.markSeen(tab: tab)
        XCTAssertNil(store.waitingSince)
    }

    func test_waitingSince_survivesTheSurfaceThatRaisedIt() {
        let start = Date(timeIntervalSince1970: 2000)
        let store = AttentionStore(now: { start })
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)

        store.release(pane)

        XCTAssertEqual(store.waitingSince, start)
    }

    func test_aWorkspaceFoldsItsTabsByMax() {
        let store = makeStore()
        let quiet = SurfaceIDs.mint()
        let loud = SurfaceIDs.mint()
        store.register(quiet, tab: tab)
        store.register(loud, tab: other)
        store.record(quiet, .completed, seen: false, focused: false)
        store.record(loud, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.state(tabs: [tab, other]), .waiting)
    }

    func test_aWorkspaceWithNoTabs_isIdle() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.state(tabs: []), .idle)
    }

    func test_aWorkspaceCountsALatchItsClosedSurfaceLeftBehind() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)

        store.release(pane)

        XCTAssertEqual(store.state(tabs: [tab]), .waiting)
    }

    func test_anAgentOnScreenButUnfocused_keepsWaiting_whileItsTabDoesNot() {
        let store = makeStore()
        let split = SurfaceIDs.mint()
        store.register(split, tab: tab)

        store.record(split, .waiting, seen: true, focused: false)

        XCTAssertEqual(store.state(tab: tab), .idle)
        XCTAssertEqual(store.agentState(of: split), .waiting)
    }

    func test_anAgentThatAsksWhileFocused_latchesNothing() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .waiting, seen: true, focused: true)

        XCTAssertEqual(store.agentState(of: pane), .idle)
    }

    func test_answeringOrVisitingTheTab_leavesTheAgentWaiting() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)

        store.markSeen(tab: tab)
        store.visit(tab) { _ in true }

        XCTAssertEqual(store.state(tab: tab), .idle)
        XCTAssertEqual(store.agentState(of: pane), .waiting)
    }

    func test_focusingTheAgent_clearsIt() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false, focused: false)

        store.markFocused(pane)

        XCTAssertEqual(store.agentState(of: pane), .idle)
        XCTAssertEqual(store.state(tab: tab), .idle)
        XCTAssertNil(store.agentSince(of: pane))
    }

    func test_aTurnEndingOutOfFocus_latchesDoneForTheAgentOnly() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.setWorking(pane, true, focused: false)
        XCTAssertEqual(store.agentState(of: pane), .working)

        store.setWorking(pane, false, focused: false)

        XCTAssertEqual(store.agentState(of: pane), .completed)
        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_aTurnEndingInFocus_leavesTheAgentIdle() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.setWorking(pane, true, focused: true)

        store.setWorking(pane, false, focused: true)

        XCTAssertEqual(store.agentState(of: pane), .idle)
    }

    func test_progressClearingWithoutATurn_latchesNothing() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.setWorking(pane, false, focused: false)

        XCTAssertEqual(store.agentState(of: pane), .idle)
    }

    func test_anAgentWaitingAfterADoneTurn_waitsSinceItAsked() {
        var clock = Date(timeIntervalSince1970: 100)
        let store = AttentionStore(now: { clock })
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.setWorking(pane, true, focused: false)
        store.setWorking(pane, false, focused: false)

        clock = Date(timeIntervalSince1970: 200)
        store.record(pane, .waiting, seen: false, focused: false)

        XCTAssertEqual(store.agentState(of: pane), .waiting)
        XCTAssertEqual(store.agentSince(of: pane), clock)
    }
}
