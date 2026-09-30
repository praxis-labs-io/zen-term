import TabKit
import XCTest

@testable import ZenTerm

final class AttentionStoreTests: XCTestCase {
    private let tab = TabID(1)
    private let other = TabID(2)

    private func makeStore(now: Date = Date(timeIntervalSince1970: 0)) -> AttentionStore {
        AttentionStore(now: { now })
    }

    func test_aTabThatCompletedBeforeItAsked_datesTheWaitFromTheQuestion() {
        var clock = Date(timeIntervalSince1970: 100)
        let store = AttentionStore(now: { clock })
        let finished = SurfaceIDs.mint()
        let asked = SurfaceIDs.mint()
        store.register(finished, tab: tab)
        store.register(asked, tab: tab)

        store.record(finished, .completed, seen: false)
        store.release(finished)
        clock = Date(timeIntervalSince1970: 200)
        store.record(asked, .waiting, seen: false)
        store.release(asked)

        XCTAssertEqual(store.state(tab: tab), .waiting, "precondition: the tab still asks")
        XCTAssertEqual(
            store.waitingSince, Date(timeIntervalSince1970: 200),
            "the wait dates from the question, not from something else finishing earlier")
    }

    func test_aPaneThatCompletedBeforeItAsked_datesTheWaitFromTheQuestion() {
        var clock = Date(timeIntervalSince1970: 100)
        let store = AttentionStore(now: { clock })
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .completed, seen: false)
        clock = Date(timeIntervalSince1970: 200)
        store.record(pane, .waiting, seen: false)

        XCTAssertEqual(store.state(tab: tab), .waiting, "precondition: the pane still asks")
        XCTAssertEqual(
            store.waitingSince, Date(timeIntervalSince1970: 200),
            "the wait dates from the question, not from its own earlier completion")
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

    func test_aWorkspaceFoldsItsTabsByMax() {
        let store = makeStore()
        let quiet = SurfaceIDs.mint()
        let loud = SurfaceIDs.mint()
        store.register(quiet, tab: tab)
        store.register(loud, tab: other)
        store.record(quiet, .completed, seen: false)
        store.record(loud, .waiting, seen: false)

        XCTAssertEqual(store.state(tabs: [tab, other]), .waiting)
    }

    func test_aWorkspaceWithNoTabs_isIdle() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)

        XCTAssertEqual(store.state(tabs: []), .idle)
    }

    func test_aWorkspaceCountsALatchItsClosedSurfaceLeftBehind() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)

        store.release(pane)

        XCTAssertEqual(store.state(tabs: [tab]), .waiting)
    }

    func test_anAgentOnScreenButUnfocused_keepsAsking_whileItsTabDoesNot() {
        let store = makeStore()
        let split = SurfaceIDs.mint()
        store.register(split, tab: tab)

        store.ask(split, seen: true)

        XCTAssertEqual(store.state(tab: tab), .idle)
        XCTAssertEqual(store.agentWait(of: split), .ask)
    }

    func test_anAgentThatAsksWhileWatched_stillAsks_andLeavesItsTabAlone() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.ask(pane, seen: true)

        XCTAssertEqual(store.agentWait(of: pane), .ask)
        XCTAssertEqual(store.state(tab: tab), .idle)
        XCTAssertEqual(store.waitingCount, 0)
    }

    func test_anAgentThatAsksWhileWatched_keepsAsking_onceTheTabIsLeft() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.ask(pane, seen: true)

        store.visit(tab) { _ in false }

        XCTAssertEqual(store.agentWait(of: pane), .ask)
    }

    func test_answeringOrVisitingTheTab_leavesAnAskStanding() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.ask(pane, seen: false)

        store.markSeen(tab: tab)
        store.visit(tab) { _ in true }

        XCTAssertEqual(store.state(tab: tab), .idle)
        XCTAssertEqual(store.agentWait(of: pane), .ask)
    }

    func test_answeringAnAsk_clearsIt_andLeavesTheTabToItsOwnAnswer() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.ask(pane, seen: false)

        store.answerAgent(pane)

        XCTAssertNil(store.agentWait(of: pane))
        XCTAssertNil(store.agentSince(of: pane))
        XCTAssertEqual(store.state(tab: tab), .waiting)
    }

    func test_workingFalling_latchesNothing() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.setWorking(pane, true)

        store.setWorking(pane, false)

        XCTAssertNil(store.agentWait(of: pane), "a turn end is the host's to judge, not the level's")
        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_aTurnEndingUnseen_waitsOnTheAgentAndTheTab() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.endTurn(pane, seen: false)

        XCTAssertEqual(store.agentWait(of: pane), .turnEnd)
        XCTAssertEqual(store.state(tab: tab), .waiting)
        XCTAssertEqual(store.waitingCount, 1)
    }

    func test_aTurnEndingSeen_latchesNothing() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.endTurn(pane, seen: true)

        XCTAssertNil(store.agentWait(of: pane))
        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_lookingAtAFinishedTurn_answersIt() {
        let store = makeStore()
        let viaPane = SurfaceIDs.mint()
        let viaVisit = SurfaceIDs.mint()
        store.register(viaPane, tab: tab)
        store.register(viaVisit, tab: other)
        store.endTurn(viaPane, seen: false)
        store.endTurn(viaVisit, seen: false)

        store.markSeen(viaPane)
        store.visit(other) { _ in true }

        XCTAssertNil(store.agentWait(of: viaPane))
        XCTAssertNil(store.agentWait(of: viaVisit))
        XCTAssertEqual(store.windowState, .idle)
    }

    func test_aNewTurn_answersAFinishedTurn_butNeverAnAsk() {
        let store = makeStore()
        let finished = SurfaceIDs.mint()
        let asking = SurfaceIDs.mint()
        store.register(finished, tab: tab)
        store.register(asking, tab: other)
        store.endTurn(finished, seen: false)
        store.ask(asking, seen: false)

        store.setWorking(finished, true)
        store.setWorking(asking, true)

        XCTAssertNil(store.agentWait(of: finished))
        XCTAssertEqual(store.state(tab: tab), .working)
        XCTAssertEqual(store.agentWait(of: asking), .ask)
    }

    func test_anAskOnAFinishedTurn_outlivesALook() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.endTurn(pane, seen: false)

        store.ask(pane, seen: false)
        store.markSeen(pane)

        XCTAssertEqual(store.agentWait(of: pane), .ask)
    }

    func test_aTurnEnd_neverReplacesAnAsk() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.ask(pane, seen: true)

        store.endTurn(pane, seen: false)

        XCTAssertEqual(store.agentWait(of: pane), .ask)
        XCTAssertEqual(store.state(tab: tab), .idle, "the ask was watched, so the tab has nothing new")
    }

    func test_answeringAFinishedTurn_clearsItsTabToo() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.endTurn(pane, seen: false)

        store.answerAgent(pane)

        XCTAssertNil(store.agentWait(of: pane))
        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_anAgentEnding_dropsAFinishedTurn() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.endTurn(pane, seen: false)

        store.endAgent(pane)

        XCTAssertNil(store.agentWait(of: pane))
        XCTAssertEqual(store.state(tab: tab), .idle)
    }

    func test_anAgentAskingAfterAFinishedTurnYouSaw_waitsSinceItAsked() {
        var clock = Date(timeIntervalSince1970: 100)
        let store = AttentionStore(now: { clock })
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.endTurn(pane, seen: false)
        store.markSeen(pane)

        clock = Date(timeIntervalSince1970: 200)
        store.ask(pane, seen: false)

        XCTAssertEqual(store.agentSince(of: pane), clock)
    }

    func test_aCrash_reportsOnce_withTheAskAlreadyInPlace() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.setWorking(pane, true)
        var seenAtReport: [AttentionStore.AgentWait?] = []
        store.onChange = { seenAtReport.append(store.agentWait(of: pane)) }

        store.endCrashedAgent(pane, seen: true)

        XCTAssertEqual(
            seenAtReport, [.ask], "a render between ending the agent and latching its crash would drop its row")
    }

    func test_anAsk_reportsOnce_evenThoughItTouchesBothLatches() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        var reports = 0
        store.onChange = { reports += 1 }

        store.ask(pane, seen: false)

        XCTAssertEqual(reports, 1, "an ask latches the tab and the agent in one change")
    }

    func test_nothingMoving_reportsNothing() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        var reports = 0
        store.onChange = { reports += 1 }

        store.markSeen(pane)
        store.setWorking(pane, false)
        store.answerAgent(pane)
        store.markSeen(tab: other)

        XCTAssertEqual(reports, 0, "a call that changes nothing must not cost a render")
    }

    func test_everyMutation_reports() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        var reports = 0
        store.onChange = { reports += 1 }

        let mutations: [(String, () -> Void)] = [
            ("register", { store.register(pane, tab: self.tab) }),
            ("setWorking on", { store.setWorking(pane, true) }),
            ("setWorking off", { store.setWorking(pane, false) }),
            ("ask", { store.ask(pane, seen: false) }),
            ("answerAgent", { store.answerAgent(pane) }),
            ("markSeen", { store.markSeen(pane) }),
            ("record", { store.record(pane, .waiting, seen: false) }),
            ("markSeen again", { store.markSeen(pane) }),
            ("endTurn", { store.endTurn(pane, seen: false) }),
            ("endAgent", { store.endAgent(pane) }),
            ("record again", { store.record(pane, .waiting, seen: false) }),
            ("markSeen(tab:)", { store.markSeen(tab: self.tab) }),
            ("record before visit", { store.record(pane, .waiting, seen: false) }),
            ("visit", { store.visit(self.tab) { _ in true } }),
            ("record completed", { store.record(pane, .completed, seen: false) }),
            ("endCrashedAgent", { store.endCrashedAgent(pane, seen: false) }),
            ("release", { store.release(pane) }),
            ("register again", { store.register(pane, tab: self.tab) }),
            ("dropTab", { store.dropTab(self.tab) }),
        ]
        for (name, mutate) in mutations {
            reports = 0
            mutate()
            XCTAssertEqual(reports, 1, name)
        }
    }
}
