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
        XCTAssertEqual(keys.args, ControlArgs(force: false, pane: 34, keys: ["down", "enter"]))
        let forced = try XCTUnwrap(
            try Zen.parseAsRoot(["pane", "keys", "34", "enter", "--force"]) as? PaneCommands.Keys)
        XCTAssertEqual(forced.args, ControlArgs(force: true, pane: 34, keys: ["enter"]))

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

    func test_everyPaneVerbTakesItsPaneAsAnArgumentOrWithPaneOption() throws {
        for verb in ["split", "focus", "close", "interrupt", "read", "get"] {
            for form in [[verb, "review"], [verb, "--pane", "review"]] {
                let parsed = try Zen.parseAsRoot(["pane"] + form)
                let pane =
                    (parsed as? PaneCommands.Split)?.pane ?? (parsed as? PaneCommands.Focus)?.pane
                    ?? (parsed as? PaneCommands.Close)?.pane ?? (parsed as? PaneCommands.Interrupt)?.pane
                    ?? (parsed as? PaneCommands.Read)?.pane ?? (parsed as? PaneCommands.Get)?.pane
                XCTAssertEqual(pane, .name("review"), "pane \(form.joined(separator: " "))")
            }
            XCTAssertEqual(
                Zen.exitCode(parsing: ["pane", verb, "31", "--pane", "31"]), 2, "pane \(verb) twice")
        }
        for form in [["wait", "review"], ["wait", "--pane", "review"]] {
            XCTAssertEqual(try XCTUnwrap(try Zen.parseAsRoot(form) as? WaitCommand).pane, .name("review"))
        }
        XCTAssertEqual(Zen.exitCode(parsing: ["wait", "31", "--pane", "31"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["wait", "--pane", "31", "--children", "any"]), 2)
    }

    func test_sendTakesThePaneBeforeTheTextOrWithPaneOption() throws {
        let leading = try XCTUnwrap(try Zen.parseAsRoot(["pane", "send", "31", "hi", "--enter"]) as? PaneCommands.Send)
        XCTAssertEqual(leading.pane, 31)
        XCTAssertEqual(leading.text, "hi")
        XCTAssertTrue(leading.enter)

        let option = try XCTUnwrap(try Zen.parseAsRoot(["pane", "send", "--pane", "31", "hi"]) as? PaneCommands.Send)
        XCTAssertEqual(option.pane, 31)
        XCTAssertEqual(option.text, "hi")

        let mine = try XCTUnwrap(try Zen.parseAsRoot(["pane", "send", "31"]) as? PaneCommands.Send)
        XCTAssertNil(mine.pane)
        XCTAssertEqual(mine.text, "31")

        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "send", "31", "hi", "--pane", "31"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "send", "31", "hi", "there"]), 2)
    }

    func test_keysTakeThePaneFirstOrWithPaneOption() throws {
        let option = try XCTUnwrap(
            try Zen.parseAsRoot(["pane", "keys", "--pane", "review", "down", "enter"]) as? PaneCommands.Keys)
        XCTAssertEqual(option.args, ControlArgs(force: false, pane: .name("review"), keys: ["down", "enter"]))

        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "keys", "31", "enter", "--pane", "31"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "keys", "--pane", "31"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "keys"]), 2)
    }

    func test_runsFloatAndTabFlagsSendFloat_andNeitherLeavesItToTheApp() throws {
        let float = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "--float", "htop"]) as? PaneCommands.Run)
        let tab = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "--tab", "htop"]) as? PaneCommands.Run)
        let neither = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "htop"]) as? PaneCommands.Run)

        XCTAssertEqual(try float.args(in: "/").float, true)
        XCTAssertEqual(try tab.args(in: "/").float, false)
        XCTAssertNil(try neither.args(in: "/").float)
        XCTAssertThrowsError(try Zen.parseAsRoot(["pane", "run", "--float", "--tab", "htop"]))
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

    func test_runCwdIsAFolderResolvedFromHere() throws {
        let here = FileManager.default.temporaryDirectory.appendingPathComponent("zen-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: here.appendingPathComponent("app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: here) }

        let run = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "--cwd", "app", "claude"]) as? PaneCommands.Run)
        XCTAssertEqual(try run.args(in: here.path).cwd, here.appendingPathComponent("app").standardizedFileURL.path)
        XCTAssertNil(
            try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "claude"]) as? PaneCommands.Run).args(in: here.path).cwd)

        let missing = try XCTUnwrap(
            try Zen.parseAsRoot(["pane", "run", "--cwd", "gone", "claude"]) as? PaneCommands.Run)
        XCTAssertThrowsError(try missing.args(in: here.path))
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
            XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run", flag]), 0)
        }
        let literal = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "--", "--help"]) as? PaneCommands.Run)
        XCTAssertEqual(literal.commandLine, "--help")
        let passed = try XCTUnwrap(try Zen.parseAsRoot(["pane", "run", "claude", "--help"]) as? PaneCommands.Run)
        XCTAssertEqual(passed.commandLine, "claude --help")
    }

    func test_runWithoutACommandOrWithADigitNameIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run", "--"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run", "--name", "42", "claude"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run", "--split", "left", "claude"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run", "--wait", "--timeout", "601", "claude"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run", "--output", "ready", "npm run dev"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run", "--wait", "--output", "", "npm run dev"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "run", "--wait", "--output", "a\nb", "npm run dev"]), 2)
    }

    func test_aBadDirectionLineCountOrKeyIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "split", "--dir", "left"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "read", "--lines", "0"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "send"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "send", "go", "--wait", "--timeout", "0"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "keys", "34", "down", "ctrl-1"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "keys", "34"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["pane", "interrupt"]), 2)
    }
}
