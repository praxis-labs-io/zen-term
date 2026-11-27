import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

final class PaneWaitLiveSurfaceTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var surfaces: [GhosttySurface] = []
    private let waits = PaneWaits()
    private let drafts = PaneDrafts()
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        var config = GeneralConfig.builtIn
        config.shell = "/bin/zsh"
        GeneralConfig.setCurrentForTesting(config)
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = GhosttySurface()
            self?.surfaces.append(surface)
            return surface
        }
    }

    override func tearDownWithError() throws {
        waits.pending.forEach { $0.cancel() }
        if let controller {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controller = nil
        surfaces.forEach { $0.terminate() }
        surfaces = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func shellPane() throws -> (surface: GhosttySurface, token: Int) {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.paneWaits = waits
        c.paneDrafts = drafts
        c.mountAndStart()
        c.window.orderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        controller = c
        let surface = try XCTUnwrap(surfaces.first)
        try XCTSkipIf(!surface.isStarted, "ghostty_surface_new failed")
        let token = try XCTUnwrap(c.listing().workspaces.first?.tabs.first?.panes.first?.token)
        waitUntil(atPrompt(surface), "the shell's first prompt", timeout: 15)
        return (surface, token)
    }

    private func atPrompt(_ surface: GhosttySurface) -> Bool {
        guard let group = surface.foregroundProcessGroupID else { return false }
        return ForegroundGroup.isShell(group) && !(surface.activeScreenText ?? "").allSatisfy(\.isWhitespace)
    }

    private final class Answer {
        var reply: ControlReply?
    }

    private func wait(on pane: Int, output: String? = nil) -> Answer {
        let answer = Answer()
        let responder = ControlResponder(
            windows: { [unowned self] in controller.map { [$0] } ?? [] }, keyWindow: { [unowned self] in controller },
            paneWaits: waits)
        responder.respond(
            to: ControlRequest(
                id: 1, cmd: .paneWait, args: ControlArgs(pane: .token(pane), output: output, timeout: 30))
        ) { answer.reply = $0 }
        return answer
    }

    private func request(_ cmd: ControlCommand, _ args: ControlArgs) throws -> ControlReply {
        var reply: ControlReply?
        ControlResponder(
            windows: { [unowned self] in controller.map { [$0] } ?? [] }, keyWindow: { [unowned self] in controller },
            paneWaits: waits
        ).respond(to: ControlRequest(id: 2, cmd: cmd, args: args)) { reply = $0 }
        return try XCTUnwrap(reply, "\(cmd.rawValue) never answered")
    }

    private func readSinceTask(_ pane: Int) throws -> PaneText {
        let reply = try request(.paneRead, ControlArgs(pane: .token(pane), since: .task))
        return try XCTUnwrap(try reply.get() as? PaneText, "\(reply)")
    }

    private func run(_ command: String, in surface: GhosttySurface) {
        surface.paste(command)
        surface.submit()
    }

    private func result(_ answer: Answer) throws -> WaitResult {
        waitUntil(answer.reply != nil, "the wait to answer", timeout: 10)
        let reply = try XCTUnwrap(answer.reply)
        return try XCTUnwrap(try reply.get() as? WaitResult, "\(reply)")
    }

    func test_anAgentReportingItsTurnDoneOverOSC7501AnswersStopped() throws {
        let (surface, token) = try shellPane()
        let report = #"printf '\033]7501;state=%s:app=claude-code\007'"#
        run("\(report) working; read -r _; \(report) done; sleep 30", in: surface)
        waitUntil(
            controller?.listing().workspaces.first?.tabs.first?.panes.first?.agent?.status == .working, "working",
            timeout: 10)
        let answer = wait(on: token)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(answer.reply, "the agent is still working")

        run("finish the turn", in: surface)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .stopped)
        XCTAssertEqual(got.pane?.agent?.status, .done)
    }

    func test_textTheProgramPrintsAnswersOutput() throws {
        let (surface, token) = try shellPane()
        let answer = wait(on: token, output: "zen-ready-42")

        run("sleep 0.5; echo zen-ready-$((40+2))", in: surface)

        XCTAssertEqual(try result(answer).reason, .output)
    }

    func test_textThatScrollsMoreThanAScreenPastBetweenChecksAnswersOutput() throws {
        let (surface, token) = try shellPane()
        let rows = try XCTUnwrap(surface.cellMetrics?.rows)
        let answer = wait(on: token, output: "zen-mid-42")

        run("sleep 0.5; seq \(rows * 4); echo zen-mid-$((40+2)); seq \(rows * 4); sleep 30", in: surface)

        XCTAssertEqual(try result(answer).reason, .output)
    }

    func test_textAcrossASoftWrapAnswersOutput() throws {
        let (surface, token) = try shellPane()
        let columns = try settledColumns(surface, try XCTUnwrap(surface.grid))
        let answer = wait(on: token, output: "zen-wrap-42")

        run("sleep 0.5; printf '%0\(columns - 4)d' 0; echo zen-wrap-$((40+2)); sleep 30", in: surface)

        XCTAssertEqual(try result(answer).reason, .output)
        let grid = try XCTUnwrap(surface.grid)
        XCTAssertTrue((0..<grid.rowCount).contains { grid.row($0)?.wraps == true }, "the needle never wrapped")
    }

    func test_textAlreadyOnScreenWhenTheWaitBeganDoesNotAnswerOutput() throws {
        let (surface, token) = try shellPane()
        run("echo zen-old-$((40+2))", in: surface)
        waitUntil((surface.activeScreenText ?? "").contains("zen-old-42"), "the old text", timeout: 10)
        waitUntil(atPrompt(surface), "the prompt after it", timeout: 10)
        let answer = wait(on: token, output: "zen-old-42")

        run("seq 3; sleep 0.5; (exit 0)", in: surface)

        XCTAssertEqual(try result(answer).reason, .exited)
    }

    func test_aFullScreenProgramDrawingTheNeedleAfterTheWaitBeganAnswersOutput() throws {
        let (surface, token) = try shellPane()
        let answer = wait(on: token, output: "zen-full-42")

        run(#"printf '\033[?1049h'; echo zen-full-$((40+2)); sleep 30"#, in: surface)

        XCTAssertEqual(try result(answer).reason, .output)
    }

    func test_twoFullScreenSessionsEachDrawingTheNeedleOnceAnswerOutput() throws {
        let (surface, token) = try shellPane()
        let answer = wait(on: token, output: "zen-again-42")
        let session = #"printf '\033[?1049h'; echo zen-again-$((40+2)); sleep 1; printf '\033[?1049l'; sleep 1"#

        run("\(session); \(session); sleep 30", in: surface)

        XCTAssertEqual(try result(answer).reason, .output)
    }

    func test_readSinceTaskReturnsOnlyWhatThePanePrintedSinceTheTask() throws {
        let (surface, token) = try shellPane()
        run("echo zen-before-$((40+2))", in: surface)
        waitUntil((surface.activeScreenText ?? "").contains("zen-before-42"), "the earlier output", timeout: 10)
        waitUntil(atPrompt(surface), "the prompt after it", timeout: 10)

        _ = try request(.paneSend, ControlArgs(pane: .token(token), text: "echo zen-after-$((40+2))", enter: true))
        waitUntil((surface.activeScreenText ?? "").contains("zen-after-42"), "the task's output", timeout: 10)

        let read = try readSinceTask(token)
        let firstLine = read.text.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        XCTAssertTrue(firstLine.contains("echo zen-after-$((40+2))"), read.text)
        XCTAssertTrue(read.text.contains("\nzen-after-42"), read.text)
        XCTAssertFalse(read.text.contains("zen-before"), read.text)
        XCTAssertEqual(read.truncated, false)
    }

    func test_readSinceTaskReadsTheTasksRowFromItsFirstColumn() throws {
        let (surface, token) = try shellPane()
        run("printf 'zen-lead-%s ' 42; read -r _; sleep 30", in: surface)
        waitUntil((surface.activeScreenText ?? "").contains("zen-lead-42 "), "the text before the cursor", timeout: 10)

        _ = try request(.paneSend, ControlArgs(pane: .token(token), text: "zen-typed", enter: true))
        waitUntil((surface.activeScreenText ?? "").contains("zen-typed"), "the task's echo", timeout: 10)

        let read = try readSinceTask(token)
        XCTAssertTrue(read.text.hasPrefix("zen-lead-42 zen-typed"), read.text)
    }

    func test_readSinceTaskOnTheAlternateScreenReadsThatScreen_andSaysSo() throws {
        let (surface, token) = try shellPane()
        let task = #"printf '\033[?1049h'; echo zen-alt-$((40+2)); sleep 30"#

        _ = try request(.paneSend, ControlArgs(pane: .token(token), text: task, enter: true))
        waitUntil((surface.activeScreenText ?? "").contains("zen-alt-42"), "the alternate screen", timeout: 10)

        let read = try readSinceTask(token)
        XCTAssertEqual(
            read.text.trimmingCharacters(in: .whitespacesAndNewlines), "zen-alt-42", "only the screen showing")
        XCTAssertEqual(read.truncated, true)
    }

    func test_aCommandThatExitsAnswersExited_withTheShellsExitCode() throws {
        let (surface, token) = try shellPane()
        let answer = wait(on: token)

        run("echo zen-failing; sleep 0.3; (exit 3)", in: surface)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 3)
        XCTAssertEqual(got.text?.contains("zen-failing"), true, got.text ?? "")
    }

    func test_thePanesShellReadsAsTheShell_andAJobItRunsDoesNot() throws {
        let (surface, _) = try shellPane()
        run("sleep 5", in: surface)
        waitUntil(
            surface.foregroundProcessGroupID.flatMap(ProcessArguments.programName(of:)) == "sleep",
            "sleep in the foreground", timeout: 10)
        let job = try XCTUnwrap(surface.foregroundProcessGroupID)
        XCTAssertFalse(ForegroundGroup.isShell(job))
    }

    func test_aKeyTypedIntoThePaneStartsADraft() throws {
        let (surface, token) = try shellPane()
        let c = try XCTUnwrap(controller)
        let place = try XCTUnwrap(c.pane(token: token))
        c.window.makeKeyAndOrderFront(nil)
        c.focus(place.pane.surfaceID, in: place.tab)
        let keys = KeyInterceptor()
        keys.onKeyToFocus = { c.keyReachedFocus($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q",
                isARepeat: false, keyCode: 12))
        XCTAssertFalse(drafts.isHolding(place.pane.surfaceID))

        c.window.sendEvent(try XCTUnwrap(keys.route(event)))

        drafts.now = { Date().addingTimeInterval(3600) }
        XCTAssertTrue(drafts.isHolding(place.pane.surfaceID), "a draft holds past the quiet pause")
        waitUntil((surface.activeScreenText ?? "").contains("q"), "the key to reach the shell", timeout: 10)
    }
}
