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
        XCTAssertEqual(plain.timeout, 90)
    }

    func test_childrenTakesThePlaceOfAPane() throws {
        let wait = try XCTUnwrap(try Zen.parseAsRoot(["wait", "--children", "all"]) as? WaitCommand)
        XCTAssertNil(wait.pane)
        XCTAssertEqual(wait.children, .all)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "34", "--children", "any"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "--children", "some"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "--children", "all", "--output", "ready"]), 2)
        XCTAssertNoThrow(try Zen.parseAsRoot(["wait", "--children", "any", "--output", "ready"]))
    }

    func test_theReplyDeadlineOutlastsTheTimeoutAndTheAppsOwnMargin() {
        let args = ControlArgs(pane: 34, timeout: 400)
        XCTAssertEqual(ControlWire.answerWait(for: .paneWait, args), 405)
        XCTAssertEqual(ControlClient.replyTimeout(for: .paneWait, args), 410)
        XCTAssertEqual(ControlWire.answerWait(for: .paneRead, args), ControlWire.longestReplyWait)
        XCTAssertEqual(ControlWire.answerWait(for: .paneSend, ControlArgs(pane: 34)), 65)
        XCTAssertEqual(ControlWire.answerWait(for: .paneSend, ControlArgs(pane: 34, timeout: 400, wait: true)), 465)
        XCTAssertEqual(ControlClient.replyTimeout(for: .paneSend, ControlArgs(pane: 34)), 70)
        XCTAssertEqual(ControlWire.answerWait(for: .paneRun, ControlArgs(cmd: "claude")), ControlWire.longestReplyWait)
        XCTAssertEqual(ControlWire.answerWait(for: .paneRun, ControlArgs(cmd: "claude", timeout: 400, wait: true)), 465)
    }

    func test_aMissingPaneOrAnOutOfRangeTimeoutIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(running: ["wait"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "34", "--timeout", "0"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "34", "--timeout", "601"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "34", "--output", ""]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["wait", "34", "--output", "built\nready"]), 2)
    }
}
