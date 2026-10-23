import TabKit
import XCTest

@testable import ZenTerm

final class AttentionCenterTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 100)

    func test_aWindowWithNobodyWaiting_isNotListed() {
        let center = AttentionCenter()

        center.update(windowID: 1, waitingCount: 0, since: nil)

        XCTAssertTrue(center.waiting.isEmpty)
    }

    func test_aWaitingWindow_carriesItsCountAndWhenItStarted() {
        let center = AttentionCenter()

        center.update(windowID: 1, waitingCount: 2, since: since)

        XCTAssertEqual(center.waiting, [WindowAttention(windowID: 1, count: 2, since: since)])
    }

    func test_theLastAgentAnswered_takesTheWindowOffTheList() {
        let center = AttentionCenter()
        center.update(windowID: 1, waitingCount: 1, since: since)

        center.update(windowID: 1, waitingCount: 0, since: nil)

        XCTAssertTrue(center.waiting.isEmpty)
    }

    func test_theOldestWaitReadsFirst() {
        let center = AttentionCenter()
        center.update(windowID: 1, waitingCount: 1, since: Date(timeIntervalSince1970: 200))
        center.update(windowID: 2, waitingCount: 1, since: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(center.waiting.map(\.windowID), [2, 1])
    }

    func test_theCountSumsAgents_notWindows() {
        let center = AttentionCenter()
        center.update(windowID: 1, waitingCount: 2, since: since)
        center.update(windowID: 2, waitingCount: 3, since: since)

        XCTAssertEqual(center.waitingCount(excluding: 9), 5)
    }

    func test_theCountLeavesOutTheWindowYouAreIn() {
        let center = AttentionCenter()
        center.update(windowID: 1, waitingCount: 2, since: since)
        center.update(windowID: 2, waitingCount: 3, since: since)

        XCTAssertEqual(center.waitingCount(excluding: 1), 3)
    }

    func test_windowsWaitingAtTheSameInstant_orderTheSameWayEveryTime() {
        let center = AttentionCenter()
        let since = Date(timeIntervalSince1970: 100)
        center.update(windowID: 7, waitingCount: 1, since: since)
        center.update(windowID: 3, waitingCount: 1, since: since)
        center.update(windowID: 5, waitingCount: 1, since: since)

        XCTAssertEqual(
            center.waiting.map(\.windowID), [3, 5, 7],
            "a tie resolves by window, so placing the row and jumping from it agree")
    }

    func test_aClosedWindow_isForgotten() {
        let center = AttentionCenter()
        center.update(windowID: 1, waitingCount: 1, since: since)

        center.forget(windowID: 1)

        XCTAssertTrue(center.waiting.isEmpty)
    }
}

final class AttentionStoreWaitingCountTests: XCTestCase {
    private let tab = TabID(1)

    private func makeStore() -> AttentionStore {
        AttentionStore(now: { Date(timeIntervalSince1970: 500) })
    }

    func test_aWorkingAgent_isNotWaiting() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.setWorking(pane, true)

        XCTAssertEqual(store.waitingCount, 0)
        XCTAssertNil(store.waitingSince)
    }

    func test_aFinishedCommand_isNotWaiting() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)

        store.record(pane, .completed, seen: false)

        XCTAssertEqual(store.waitingCount, 0, "a command that finished is not asking you for anything")
        XCTAssertNil(store.waitingSince)
    }

    func test_eachWaitingAgentCountsOnce() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        let b = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.register(b, tab: tab)

        store.record(a, .waiting, seen: false)
        store.record(b, .waiting, seen: false)

        XCTAssertEqual(store.waitingCount, 2)
    }

    func test_anAgentYouHaveSeen_stopsCounting() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)

        store.markSeen(tab: tab)

        XCTAssertEqual(store.waitingCount, 0)
    }

    func test_anAgentThatExitedWhileWaiting_stillCounts() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .waiting, seen: false)

        store.release(pane)

        XCTAssertEqual(
            store.waitingCount, 1,
            "it asked and you never looked, which is exactly why its tab is still marked")
    }

    func test_twoAgentsThatExitedWhileWaitingInOneTab_countTwice() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        let b = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.register(b, tab: tab)
        store.record(a, .waiting, seen: false)
        store.record(b, .waiting, seen: false)

        store.release(a)
        store.release(b)

        XCTAssertEqual(store.waitingCount, 2, "two agents asked, so N is two however many tabs they shared")
    }

    func test_visitingATab_clearsEveryAgentItRemembers() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        let b = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.register(b, tab: tab)
        store.record(a, .waiting, seen: false)
        store.record(b, .waiting, seen: false)
        store.release(a)
        store.release(b)

        store.markSeen(tab: tab)

        XCTAssertEqual(store.waitingCount, 0)
    }

    func test_closingATab_forgetsTheAgentsItRemembers() {
        let store = makeStore()
        let a = SurfaceIDs.mint()
        store.register(a, tab: tab)
        store.record(a, .waiting, seen: false)
        store.release(a)

        store.dropTab(tab)

        XCTAssertEqual(store.waitingCount, 0)
    }

    func test_aCompletionThatExited_doesNotCount() {
        let store = makeStore()
        let pane = SurfaceIDs.mint()
        store.register(pane, tab: tab)
        store.record(pane, .completed, seen: false)

        store.release(pane)

        XCTAssertEqual(store.waitingCount, 0)
        XCTAssertNil(store.waitingSince)
    }
}
