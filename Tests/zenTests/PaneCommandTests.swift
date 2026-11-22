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
        XCTAssertFalse(send.wait)
        XCTAssertFalse(send.force)

        let waiting = try XCTUnwrap(
            try Zen.parseAsRoot(["pane", "send", "go", "--wait", "--timeout", "30", "--force"]) as? PaneCommands.Send)
        XCTAssertTrue(waiting.wait)
        XCTAssertTrue(waiting.force)
        XCTAssertEqual(waiting.timeout, 30)

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

        XCTAssertEqual(try XCTUnwrap(try Zen.parseAsRoot(["pane", "get", "34"]) as? PaneCommands.Get).pane, 34)
        XCTAssertNil(try XCTUnwrap(try Zen.parseAsRoot(["pane", "get"]) as? PaneCommands.Get).pane)
    }

    func test_aPaneArgumentTakesAName() throws {
        let focus = try XCTUnwrap(try Zen.parseAsRoot(["pane", "focus", "review"]) as? PaneCommands.Focus)
        XCTAssertEqual(focus.pane, .name("review"))
        let send = try XCTUnwrap(try Zen.parseAsRoot(["pane", "send", "hi", "--pane", "review"]) as? PaneCommands.Send)
        XCTAssertEqual(send.pane, .name("review"))
        XCTAssertEqual(
            try XCTUnwrap(try Zen.parseAsRoot(["pane", "get", "review"]) as? PaneCommands.Get).pane, .name("review"))
        let keys = try XCTUnwrap(try Zen.parseAsRoot(["pane", "keys", "review", "enter"]) as? PaneCommands.Keys)
        XCTAssertEqual(keys.pane, .name("review"))
        let interrupt = try XCTUnwrap(try Zen.parseAsRoot(["pane", "interrupt", "review"]) as? PaneCommands.Interrupt)
        XCTAssertEqual(interrupt.pane, .name("review"))
        XCTAssertEqual(try XCTUnwrap(try Zen.parseAsRoot(["wait", "review"]) as? WaitCommand).pane, .name("review"))
    }

    func test_runTakesItsOptionsThenTheWholeCommand() throws {
        let run = try XCTUnwrap(
            try Zen.parseAsRoot([
                "pane", "run", "--name", "review", "--task", "Review x.swift", "--split", "down", "--pane", "31",
                "--focus", "--keep", "--outlive-parent", "claude", "--model", "opus",
            ]) as? PaneCommands.Run)
        XCTAssertEqual(run.name, "review")
        XCTAssertEqual(run.task, "Review x.swift")
        XCTAssertEqual(run.split, .down)
        XCTAssertEqual(run.pane, 31)
        XCTAssertTrue(run.focus)
        XCTAssertTrue(run.keep)
        XCTAssertTrue(run.outliveParent)
        XCTAssertEqual(run.command, ["claude", "--model", "opus"])

        let plain = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "npm run dev"]) as? PaneCommands.Run)
        XCTAssertEqual(plain.command, ["npm run dev"])
        XCTAssertNil(plain.split)
        XCTAssertFalse(plain.keep)
        XCTAssertFalse(plain.outliveParent)
        XCTAssertFalse(plain.wait)

        let waiting = try XCTUnwrap(
            try Zen.parseAsRoot(["pane", "run", "--wait", "--timeout", "30", "claude"]) as? PaneCommands.Run)
        XCTAssertTrue(waiting.wait)
        XCTAssertEqual(waiting.timeout, 30)
        XCTAssertEqual(waiting.command, ["claude"])

        let server = try XCTUnwrap(
            try Zen.parseAsRoot([
                "pane", "run", "--name", "dev", "--wait", "--output", "ready on", "--", "npm", "run", "dev",
            ]) as? PaneCommands.Run)
        XCTAssertEqual(server.output, "ready on")
        XCTAssertEqual(server.commandLine, "npm run dev")
    }

    func test_runSendsOneArgumentAsALineAndQuotesSeveral() throws {
        let separated = try XCTUnwrap(
            try Zen.parseAsRoot(["pane", "run", "--name", "dev", "--", "sh", "-c", "sleep 1"]) as? PaneCommands.Run)
        XCTAssertEqual(separated.commandLine, "sh -c 'sleep 1'")

        let words = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "echo", "it's"]) as? PaneCommands.Run)
        XCTAssertEqual(words.commandLine, "echo 'it'\\''s'")

        let line = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "npm run dev && exit"]) as? PaneCommands.Run)
        XCTAssertEqual(line.commandLine, "npm run dev && exit")
    }

    func test_runAsksForHelpBeforeACommandAndRunsItAfterTheSeparator() throws {
        for flag in ["--help", "-h"] {
            XCTAssertThrowsError(try Zen.parseAsRoot(["pane", "run", flag])) {
                XCTAssertEqual(Zen.exitCode(for: $0), .success)
                XCTAssertTrue(Zen.fullMessage(for: $0).contains("--outlive-parent"), "\(flag) prints pane run's help")
            }
            XCTAssertEqual(Zen.exitCode(running: ["pane", "run", flag]), 0)
        }
        let literal = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "--", "--help"]) as? PaneCommands.Run)
        XCTAssertEqual(literal.commandLine, "--help")
        let passed = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "claude", "--help"]) as? PaneCommands.Run)
        XCTAssertEqual(passed.commandLine, "claude --help")
    }

    func test_runWithoutACommandOrWithADigitNameIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(running: ["pane", "run"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "run", "--"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "run", "--name", "42", "claude"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "run", "--split", "left", "claude"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "run", "--wait", "--timeout", "601", "claude"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "run", "--output", "ready", "npm run dev"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "run", "--wait", "--output", "", "npm run dev"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "run", "--wait", "--output", "a\nb", "npm run dev"]), 2)
    }

    func test_aBadDirectionLineCountOrKeyIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(running: ["pane", "split", "--dir", "left"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "read", "--lines", "0"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "send"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "send", "go", "--wait", "--timeout", "0"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "keys", "34", "down", "ctrl-1"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "keys", "34"]), 2)
        XCTAssertEqual(Zen.exitCode(running: ["pane", "interrupt"]), 2)
    }
}
