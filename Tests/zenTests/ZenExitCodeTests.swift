import XCTest

@testable import zen

final class ZenExitCodeTests: XCTestCase {
    func test_anUnknownFlagIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(running: ["list", "--bogus"]), 2)
    }

    func test_anUnknownCommandIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(running: ["frobnicate"]), 2)
    }

    func test_aSocketWithNothingListeningIsNoInstance() {
        XCTAssertEqual(Zen.exitCode(running: ["list", "--socket", "/tmp/zt-nothing-\(getpid()).sock"]), 3)
    }

    func test_versionIsNotAFailure() {
        XCTAssertEqual(Zen.exitCode(running: ["--version"]), 0)
    }

    func test_helpIsNotAFailure() {
        XCTAssertEqual(Zen.exitCode(running: ["--help"]), 0)
    }
}
