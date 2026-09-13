import XCTest

extension XCTestCase {
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
