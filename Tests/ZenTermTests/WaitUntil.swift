import XCTest

extension XCTestCase {
    /// Pump the main run loop until `condition` holds, then return. For observing work that lands
    /// back on the main queue from a background probe (`GitRepoStatus.refresh`).
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
