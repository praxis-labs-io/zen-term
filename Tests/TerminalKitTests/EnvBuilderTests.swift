import XCTest

@testable import TerminalKit

final class EnvBuilderTests: XCTestCase {
    func test_noOverridesReturnsBaseUnchanged() {
        let base = ["PATH=/usr/bin", "TERM=xterm"]
        XCTAssertEqual(EnvBuilder.merged(base: base, overrides: [:]), base)
    }

    func test_overrideReplacesExistingKeyInPlace() {
        let base = ["PATH=/usr/bin", "TERM=xterm"]
        let result = EnvBuilder.merged(base: base, overrides: ["TERM": "xterm-256color"])
        XCTAssertEqual(result, ["PATH=/usr/bin", "TERM=xterm-256color"])
    }

    func test_newKeysAppendedInSortedOrder() {
        let base = ["PATH=/usr/bin"]
        let result = EnvBuilder.merged(base: base, overrides: ["ZED": "1", "ABLE": "1"])
        XCTAssertEqual(result, ["PATH=/usr/bin", "ABLE=1", "ZED=1"])
    }
}
