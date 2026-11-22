import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlPaneWaitTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private let waits = PaneWaits()
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        waits.pending.forEach { $0.cancel() }
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.paneWaits = waits
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first },
            paneWaits: waits)
    }

    private final class Answer {
        var reply: ControlReply?
    }

    private func wait(
        on pane: Int?, output: String? = nil, timeout: Int? = nil, from caller: Int? = nil,
        hangup: ControlHangup = ControlHangup()
    ) -> Answer {
        let answer = Answer()
        responder.respond(
            to: ControlRequest(
                id: 1, cmd: .paneWait, args: ControlArgs(pane: pane, output: output, timeout: timeout),
                caller: caller.map(ControlCaller.init(pane:))),
            hangup: hangup
        ) { answer.reply = $0 }
        return answer
    }

    private func send(_ cmd: ControlCommand, _ args: ControlArgs) {
        responder.respond(to: ControlRequest(id: 2, cmd: cmd, args: args)) { _ in }
    }

    private func result(_ answer: Answer, within timeout: TimeInterval = 2) throws -> WaitResult {
        waitUntil(answer.reply != nil, "the wait to answer", timeout: timeout)
        let reply = try XCTUnwrap(answer.reply)
        return try XCTUnwrap(try reply.get() as? WaitResult, "\(reply)")
    }

    private func token(of surface: RecordingSurface) throws -> Int {
        try XCTUnwrap(surface.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
    }

    private func report(_ state: TerminalProgramStatus.State, from surface: RecordingSurface) {
        surface.delegate?.surface(
            surface, programStatusDidChange: TerminalProgramStatus(state: state, app: "claude-code"))
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func test_aWorkingAgentThatFinishesAnswersStopped_withItsPaneAsPaneGetReportsIt() throws {
        makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.working, from: agent)
        let answer = wait(on: try token(of: agent))
        settle(0.3)
        XCTAssertNil(answer.reply, "a working agent holds the wait")

        report(.done, from: agent)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .stopped)
        XCTAssertEqual(got.pane.token, try token(of: agent))
        XCTAssertEqual(got.pane.agent?.status, .done)
        XCTAssertTrue(waits.pending.isEmpty)
    }

    func test_anAgentThatIsNotWorkingWhenTheWaitBeginsHoldsUntilItWorksAndStops() throws {
        makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.idle, from: agent)
        let answer = wait(on: try token(of: agent))

        report(.done, from: agent)
        settle(0.3)
        XCTAssertNil(answer.reply)

        report(.working, from: agent)
        report(.blocked(.permission), from: agent)
        XCTAssertEqual(try result(answer).reason, .stopped)
    }

    func test_aWaitThatHearsNothingAnswersTimeout() throws {
        makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let started = Date()

        let got = try result(wait(on: try token(of: pane), timeout: 1), within: 3)

        XCTAssertEqual(got.reason, .timeout)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1)
    }

    func test_aFinishedCommandAnswersExited_withItsExitCodeAndLastLines() throws {
        makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let answer = wait(on: try token(of: pane))
        pane.rows = []
        pane.scrollback = ["$ make test", "1 test failed"]

        pane.delegate?.surface(pane, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 2))

        let got = try result(answer)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 3)
        XCTAssertEqual(got.text, "$ make test\n1 test failed")
    }

    func test_aPaneThatClosesAnswersExited() throws {
        makeWindow()
        let first = try XCTUnwrap(spawned.first)
        send(.paneSplit, ControlArgs(pane: try token(of: first), dir: .right))
        let second = try XCTUnwrap(spawned.last)
        let answer = wait(on: try token(of: second))

        send(.paneClose, ControlArgs(force: true, pane: try token(of: second)))

        let got = try result(answer)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.pane.token, try token(of: second))
        XCTAssertNil(got.exitCode)
    }

    func test_textSentToTheWaitingCallersOwnPaneAnswersMessage() throws {
        makeWindow()
        let caller = try XCTUnwrap(spawned.first)
        send(.paneSplit, ControlArgs(pane: try token(of: caller), dir: .right))
        let helper = try XCTUnwrap(spawned.last)
        let answer = wait(on: try token(of: helper), from: try token(of: caller))

        send(.paneSend, ControlArgs(pane: try token(of: helper), text: "to the helper"))
        settle(0.3)
        XCTAssertNil(answer.reply, "a send to the pane waited on is not a message for the caller")

        send(.paneSend, ControlArgs(pane: try token(of: caller), text: "done: 2 bugs"))

        let got = try result(answer)
        XCTAssertEqual(got.reason, .message)
        XCTAssertEqual(got.pane.token, try token(of: helper))
    }

    func test_outputPrintedAfterTheWaitBeganAnswersOutput_andTextAlreadyThereDoesNot() throws {
        makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.rows = ["server ready (old)", "$ npm run dev"]
        let answer = wait(on: try token(of: pane), output: "ready")
        pane.rows = ["server ready (old)", "$ npm run dev", "compiling"]
        settle(0.6)
        XCTAssertNil(answer.reply)

        pane.rows = ["server ready (old)", "$ npm run dev", "compiling", "server ready"]

        XCTAssertEqual(try result(answer).reason, .output)
    }

    func test_anOutputWaitIgnoresTheAgentStopping() throws {
        makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.working, from: agent)
        let answer = wait(on: try token(of: agent), output: "ready")

        report(.done, from: agent)
        settle(0.3)

        XCTAssertNil(answer.reply)
    }

    func test_aJobGivingTheForegroundBackToTheShellAnswersExited_withoutShellIntegration() throws {
        makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let job = try spawn("/bin/sleep", ["30"])
        let shell = try sessionLeader()
        defer {
            job.terminate()
            kill(shell, SIGTERM)
        }
        XCTAssertFalse(ForegroundGroup.isShell(job.processIdentifier))
        XCTAssertTrue(ForegroundGroup.isShell(shell))
        pane.foregroundProcessGroupID = shell
        let answer = wait(on: try token(of: pane))

        pane.foregroundProcessGroupID = job.processIdentifier
        settle(0.6)
        XCTAssertNil(answer.reply, "a job starting is not an exit")
        pane.foregroundProcessGroupID = shell

        let got = try result(answer)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertNil(got.exitCode)
    }

    private func sessionLeader() throws -> pid_t {
        let pipe = Pipe()
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        launcher.arguments = [
            "-MPOSIX", "-e", "exit 0 if fork; POSIX::setsid(); print \"$$\\n\"; close STDOUT; sleep 30",
        ]
        launcher.standardOutput = pipe
        try launcher.run()
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try XCTUnwrap(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)), line)
        XCTAssertEqual(getsid(pid), pid)
        return pid
    }

    private func spawn(_ path: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        return process
    }

    func test_aHangupDropsTheWaitWithoutAnswering() throws {
        makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let hangup = ControlHangup()
        let answer = wait(on: try token(of: pane), hangup: hangup)
        XCTAssertEqual(waits.pending.count, 1)

        hangup.hangUp()
        pane.delegate?.surface(pane, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        settle(0.3)

        XCTAssertTrue(waits.pending.isEmpty)
        XCTAssertNil(answer.reply)
    }

    func test_aWaitNeedsAPaneThatExists_aTimeoutInRange_andTextToWaitFor() throws {
        makeWindow()
        let pane = try token(of: try XCTUnwrap(spawned.first))
        let cases: [(Answer, ControlErrorCode)] = [
            (wait(on: nil), .badRequest), (wait(on: pane, timeout: 0), .badRequest),
            (wait(on: pane, timeout: ControlWire.longestPaneWait + 1), .badRequest),
            (wait(on: pane, output: ""), .badRequest), (wait(on: pane, output: "built\nready"), .badRequest),
            (wait(on: 9999), .notFound),
        ]
        for (answer, code) in cases {
            guard case .failure(let error) = answer.reply else {
                return XCTFail("expected \(code), got \(answer.reply as Any)")
            }
            XCTAssertEqual(error.code, code, error.message)
        }
        XCTAssertTrue(waits.pending.isEmpty)
    }
}
