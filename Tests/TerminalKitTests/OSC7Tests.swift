import XCTest

@testable import TerminalKit

final class OSC7Tests: XCTestCase {
    func test_plainPath() {
        XCTAssertEqual(OSC7.fileURL(from: "/Users/me/dev")?.path, "/Users/me/dev")
    }

    func test_pathWithSpaces() {
        XCTAssertEqual(OSC7.fileURL(from: "/Users/me/my project")?.path, "/Users/me/my project")
    }

    func test_fileURLScheme() {
        XCTAssertEqual(OSC7.fileURL(from: "file:///Users/me/dev")?.path, "/Users/me/dev")
    }

    func test_fileURLSchemeWithPercentEncodedSpace() {
        XCTAssertEqual(OSC7.fileURL(from: "file:///Users/me/my%20project")?.path, "/Users/me/my project")
    }

    func test_emptyIsNil() {
        XCTAssertNil(OSC7.fileURL(from: "   "))
    }
}
