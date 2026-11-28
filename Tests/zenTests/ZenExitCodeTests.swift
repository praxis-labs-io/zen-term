import XCTest

@testable import zen

final class ZenExitCodeTests: XCTestCase {
    func test_anUnknownFlagIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(parsing: ["list", "--bogus"]), 2)
    }

    func test_anUnknownCommandIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(parsing: ["frobnicate"]), 2)
    }

    func test_aSocketWithNothingListeningIsNoInstance() {
        XCTAssertEqual(Zen.exitCode(running: ["list", "--socket", Zen.unreachableSocket]), 3)
    }

    func test_versionIsNotAFailure() {
        XCTAssertEqual(Zen.exitCode(parsing: ["--version"]), 0)
    }

    func test_helpIsNotAFailure() {
        XCTAssertEqual(Zen.exitCode(parsing: ["--help"]), 0)
    }
}
