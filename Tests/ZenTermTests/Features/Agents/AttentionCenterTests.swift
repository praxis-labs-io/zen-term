import TabKit
import XCTest

@testable import ZenTerm

final class AttentionCenterTests: XCTestCase {
    func test_aWindowWithNobodyWaiting_countsNothing() {
        let center = AttentionCenter()

        center.update(windowID: 1, blockedCount: 0)

        XCTAssertEqual(center.blockedCount(excluding: 9), 0)
    }

    func test_theLastAgentAnswered_takesTheWindowsCountAway() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 1)

        center.update(windowID: 1, blockedCount: 0)

        XCTAssertEqual(center.blockedCount(excluding: 9), 0)
    }

    func test_theCountSumsAgents_notWindows() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 2)
        center.update(windowID: 2, blockedCount: 3)

        XCTAssertEqual(center.blockedCount(excluding: 9), 5)
    }

    func test_theCountLeavesOutTheWindowYouAreIn() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 2)
        center.update(windowID: 2, blockedCount: 3)

        XCTAssertEqual(center.blockedCount(excluding: 1), 3)
    }

    func test_aClosedWindow_isForgotten() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 1)

        center.forget(windowID: 1)

        XCTAssertEqual(center.blockedCount(excluding: 9), 0)
    }
}

final class AttentionStoreBlockedCountTests: XCTestCase {
    private let tab = TabID(1)

    private func makeStore() -> AttentionStore {
        AttentionStore(now: { Date(timeIntervalSince1970: 500) })
    }

    func test_aWorkingAgent_isNotWaiting() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.setWorking(pane, true)

        XCTAssertEqual(store.blockedCount, 0)
    }

    func test_aFinishedCommand_isNotBlocked() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .completed, seen: false)

        XCTAssertEqual(store.blockedCount, 0, "a command that finished is not asking you for anything")
    }

    func test_eachBlockedAgentCountsOnce() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        let b = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.register(b, tab: tab)

        store.ask(a, seen: false)
        store.ask(b, seen: false)

        XCTAssertEqual(store.blockedCount, 2)
    }

    func test_anAgentYouHaveSeen_stopsCounting() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.ask(pane, seen: false)

        store.markSeen(tab: tab)

        XCTAssertEqual(store.blockedCount, 0)
    }

    func test_anAgentThatExitedWhileBlocked_stillCounts() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.ask(pane, seen: false)

        store.release(pane)

        XCTAssertEqual(
            store.blockedCount, 1,
            "it asked and you never looked, which is exactly why its tab is still marked")
    }

    func test_twoAgentsThatExitedWhileBlockedInOneTab_countTwice() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        let b = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.register(b, tab: tab)
        store.ask(a, seen: false)
        store.ask(b, seen: false)

        store.release(a)
        store.release(b)

        XCTAssertEqual(store.blockedCount, 2, "two agents asked, so N is two however many tabs they shared")
    }

    func test_visitingATab_clearsEveryAgentItRemembers() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        let b = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.register(b, tab: tab)
        store.ask(a, seen: false)
        store.ask(b, seen: false)
        store.release(a)
        store.release(b)

        store.markSeen(tab: tab)

        XCTAssertEqual(store.blockedCount, 0)
    }

    func test_closingATab_forgetsTheAgentsItRemembers() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.ask(a, seen: false)
        store.release(a)

        store.dropTab(tab)

        XCTAssertEqual(store.blockedCount, 0)
    }

    func test_aCompletionThatExited_doesNotCount() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .completed, seen: false)

        store.release(pane)

        XCTAssertEqual(store.blockedCount, 0)
    }
}
