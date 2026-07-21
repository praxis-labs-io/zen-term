import XCTest

@testable import AppLog

final class LogEntryTests: XCTestCase {
    func testFileLineFormatsIso8601WithLevelAndCategory() {
        let entry = LogEntry(
            level: .warning, category: "nav", message: "bind failed",
            timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(entry.fileLine(), "1970-01-01T00:00:00Z  WARN  [nav]  bind failed")
    }
}
