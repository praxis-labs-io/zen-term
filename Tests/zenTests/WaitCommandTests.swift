import ArgumentParser
import ControlProtocol
import XCTest

@testable import zen

final class WaitCommandTests: XCTestCase {
    func test_waitParsesItsPaneOutputAndTimeout() throws {
        let wait = try XCTUnwrap(
            try Zen.parseAsRoot(["wait", "34", "--output", "ready", "--timeout", "30"]) as? WaitCommand)
        XCTAssertEqual(wait.pane, 34)
        XCTAssertEqual(wait.output, "ready")
        XCTAssertEqual(wait.timeout, 30)

        let plain = try XCTUnwrap(try Zen.parseAsRoot(["wait", "34"]) as? WaitCommand)
        XCTAssertNil(plain.output)
        XCTAssertEqual(plain.timeout, ControlWire.defaultPaneWait)
    }

    func test_theReplyDeadlineOutlastsTheTimeoutAndTheAppsOwnMargin() {
        let args = ControlArgs(pane: 34, timeout: 400)
        XCTAssertEqual(ControlWire.answerWait(for: .paneWait, args), 405)
        XCTAssertEqual(WaitCommand.replyTimeout(for: args), 410)
        XCTAssertEqual(ControlWire.answerWait(for: .paneRead, args), ControlWire.longestReplyWait)
    }

    func test_aMissingPaneOrAnOutOfRangeTimeoutIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(running: ["wait"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "34", "--timeout", "0"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "34", "--timeout", "601"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "34", "--output", ""]), 2)
    }
}
