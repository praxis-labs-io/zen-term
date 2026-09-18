import XCTest

@testable import ZenTerm

final class AttentionCenterTests: XCTestCase {
    func test_anIdleWindow_isNotListed() {
        let center = AttentionCenter()

        center.update(windowID: 1, state: .idle, since: nil)

        XCTAssertTrue(center.waiting.isEmpty)
    }

    func test_aWaitingWindow_isListedWithWhenItStarted() {
        let center = AttentionCenter()
        let since = Date(timeIntervalSince1970: 100)

        center.update(windowID: 1, state: .waiting, since: since)

        XCTAssertEqual(center.waiting, [WindowAttention(windowID: 1, state: .waiting, since: since)])
    }

    func test_goingIdle_takesAWindowOffTheList() {
        let center = AttentionCenter()
        center.update(windowID: 1, state: .waiting, since: Date(timeIntervalSince1970: 100))

        center.update(windowID: 1, state: .idle, since: nil)

        XCTAssertTrue(center.waiting.isEmpty)
    }

    func test_theOldestWaitReadsFirst() {
        let center = AttentionCenter()
        center.update(windowID: 1, state: .waiting, since: Date(timeIntervalSince1970: 200))
        center.update(windowID: 2, state: .completed, since: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(center.waiting.map(\.windowID), [2, 1])
    }

    func test_aClosedWindow_isForgotten() {
        let center = AttentionCenter()
        center.update(windowID: 1, state: .waiting, since: Date(timeIntervalSince1970: 100))

        center.forget(windowID: 1)

        XCTAssertTrue(center.waiting.isEmpty)
    }
}
