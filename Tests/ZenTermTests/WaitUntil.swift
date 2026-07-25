import XCTest

@testable import ZenTerm

extension XCTestCase {
    /// Wait until every config write already enqueued has been written, re-resolved, and applied.
    ///
    /// `AppConfig` does its file I/O on one serial queue and delivers back on main in order
    /// (ZEN-17), so a barrier enqueued *behind* the work under test can only run after it. That
    /// ordering is what lets a test assert a keystroke wrote nothing: a fixed delay passes just as
    /// happily when nothing had time to happen yet, which is the opposite of what's being asserted.
    ///
    /// Call it in `tearDown` too, in any test that points `ConfigLoader.defaultRootOverrideForTesting`
    /// at a temp root — a write still in flight when the override is cleared lands in the real
    /// `~/.config/zen-term`.
    func drainConfigWrites(timeout: TimeInterval = 2) {
        let drained = expectation(description: "config writes drained")
        AppConfig.drainForTesting { drained.fulfill() }
        wait(for: [drained], timeout: timeout)
    }

    /// Pump the main run loop until `condition` holds, then return. For observing work that lands
    /// back on the main queue from a background probe (`GitRepoStatus.refresh`, ZEN-15).
    ///
    /// Waiting on the condition rather than on a fixed delay is what keeps the test both fast and
    /// honest: it returns the moment the state flips instead of always paying the delay, and it
    /// can't pass on a slow machine that simply hadn't got there yet. A timeout fails the test
    /// naming what never happened, rather than letting the assertions after it read stale state.
    func waitUntil(
        _ condition: @autoclosure () -> Bool, _ description: String, timeout: TimeInterval = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }
}
