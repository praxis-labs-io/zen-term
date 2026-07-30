import XCTest

@testable import ZenTerm

/// FSEvents delivery belongs in the runbook; the silent failure worth pinning here is the trailing
/// debounce firing once per raw event, or firing after its owner has stopped.
final class RepoWatcherTests: XCTestCase {
    func test_eventBurst_firesOnlyTheTrailingCallback() {
        var scheduled: [() -> Void] = []
        var calls = 0
        let debouncer = TrailingDebouncer(
            delay: 0.275,
            schedule: { _, work in scheduled.append(work) })
        debouncer.setAction { calls += 1 }

        debouncer.signal()
        debouncer.signal()
        debouncer.signal()
        scheduled.forEach { $0() }

        XCTAssertEqual(calls, 1, "one filesystem burst should cause one settled refresh")
    }

    func test_cancel_invalidatesAPendingCallback() {
        var scheduled: [() -> Void] = []
        var calls = 0
        let debouncer = TrailingDebouncer(
            delay: 0.275,
            schedule: { _, work in scheduled.append(work) })
        debouncer.setAction { calls += 1 }

        debouncer.signal()
        debouncer.cancel()
        scheduled.forEach { $0() }

        XCTAssertEqual(calls, 0, "closing the viewer must invalidate its pending refresh")
    }
}
