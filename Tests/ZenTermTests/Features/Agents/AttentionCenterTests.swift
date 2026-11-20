import TabKit
import XCTest

@testable import ZenTerm

final class AttentionCenterTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 100)

    func test_aWindowWithNobodyWaiting_isNotListed() {
        let center = AttentionCenter()

        center.update(windowID: 1, blockedCount: 0, since: nil)

        XCTAssertTrue(center.blocked.isEmpty)
    }

    func test_aWaitingWindow_carriesItsCountAndWhenItStarted() {
        let center = AttentionCenter()

        center.update(windowID: 1, blockedCount: 2, since: since)

        XCTAssertEqual(center.blocked, [WindowAttention(windowID: 1, count: 2, since: since)])
    }

    func test_theLastAgentAnswered_takesTheWindowOffTheList() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 1, since: since)

        center.update(windowID: 1, blockedCount: 0, since: nil)

        XCTAssertTrue(center.blocked.isEmpty)
    }

    func test_theOldestWaitReadsFirst() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 1, since: Date(timeIntervalSince1970: 200))
        center.update(windowID: 2, blockedCount: 1, since: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(center.blocked.map(\.windowID), [2, 1])
    }

    func test_theCountSumsAgents_notWindows() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 2, since: since)
        center.update(windowID: 2, blockedCount: 3, since: since)

        XCTAssertEqual(center.blockedCount(excluding: 9), 5)
    }

    func test_theCountLeavesOutTheWindowYouAreIn() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 2, since: since)
        center.update(windowID: 2, blockedCount: 3, since: since)

        XCTAssertEqual(center.blockedCount(excluding: 1), 3)
    }

    func test_windowsWaitingAtTheSameInstant_orderTheSameWayEveryTime() {
        let center = AttentionCenter()
        let since = Date(timeIntervalSince1970: 100)
        center.update(windowID: 7, blockedCount: 1, since: since)
        center.update(windowID: 3, blockedCount: 1, since: since)
        center.update(windowID: 5, blockedCount: 1, since: since)

        XCTAssertEqual(
            center.blocked.map(\.windowID), [3, 5, 7],
            "a tie resolves by window, so placing the row and jumping from it agree")
    }

    func test_aClosedWindow_isForgotten() {
        let center = AttentionCenter()
        center.update(windowID: 1, blockedCount: 1, since: since)

        center.forget(windowID: 1)

        XCTAssertTrue(center.blocked.isEmpty)
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
        XCTAssertNil(store.blockedSince)
    }

    func test_aFinishedCommand_isNotBlocked() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .completed, seen: false)

        XCTAssertEqual(store.blockedCount, 0, "a command that finished is not asking you for anything")
        XCTAssertNil(store.blockedSince)
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
        XCTAssertNil(store.blockedSince)
    }
}
