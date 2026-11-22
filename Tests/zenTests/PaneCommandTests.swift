import ArgumentParser
import ControlProtocol
import XCTest

@testable import zen

final class PaneCommandTests: XCTestCase {
    func test_theSubcommandsParseTheirArguments() throws {
        let split = try XCTUnwrap(
            try Zen.parseAsRoot(["pane", "split", "--dir", "down", "--cmd", "make watch", "--pane", "31", "--focus"])
                as? PaneCommands.Split)
        XCTAssertEqual(split.dir, .down)
        XCTAssertEqual(split.cmd, "make watch")
        XCTAssertEqual(split.pane, 31)
        XCTAssertTrue(split.focus)
        XCTAssertEqual(try XCTUnwrap(try Zen.parseAsRoot(["pane", "split"]) as? PaneCommands.Split).dir, .right)

        let send = try XCTUnwrap(
            try Zen.parseAsRoot(["pane", "send", "echo hi", "--enter", "--pane", "7"]) as? PaneCommands.Send)
        XCTAssertEqual(send.text, "echo hi")
        XCTAssertTrue(send.enter)
        XCTAssertEqual(send.pane, 7)

        let read = try XCTUnwrap(try Zen.parseAsRoot(["pane", "read", "--lines", "100"]) as? PaneCommands.Read)
        XCTAssertEqual(read.lines, 100)
        XCTAssertNil(read.pane)

        let close = try XCTUnwrap(try Zen.parseAsRoot(["pane", "close", "31", "--force"]) as? PaneCommands.Close)
        XCTAssertEqual(close.pane, 31)
        XCTAssertTrue(close.force)

        XCTAssertEqual(try XCTUnwrap(try Zen.parseAsRoot(["pane", "focus", "32"]) as? PaneCommands.Focus).pane, 32)

        let keys = try XCTUnwrap(try Zen.parseAsRoot(["pane", "keys", "34", "down", "enter"]) as? PaneCommands.Keys)
        XCTAssertEqual(keys.pane, 34)
        XCTAssertEqual(keys.keys, [.down, .enter])

        let interrupt = try XCTUnwrap(try Zen.parseAsRoot(["pane", "interrupt", "34"]) as? PaneCommands.Interrupt)
        XCTAssertEqual(interrupt.pane, 34)
    }

    func test_aBadDirectionLineCountOrKeyIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(running: ["pane", "split", "--dir", "left"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "read", "--lines", "0"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "send"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "keys", "34", "down", "ctrl-1"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "keys", "34"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "interrupt"]), 2)
    }
}
