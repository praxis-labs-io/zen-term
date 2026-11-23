import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlChildrenWaitTests: WindowTestCase {
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
        waits.childrenWaits.forEach { $0.cancel() }
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
            initialCWD: FileManager.default.temporaryDirectory, firstTaskWindow: 5)
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

    private func request(_ cmd: ControlCommand, _ args: ControlArgs, from caller: Int?) -> Answer {
        let answer = Answer()
        responder.respond(
            to: ControlRequest(id: 1, cmd: cmd, args: args, caller: caller.map(ControlCaller.init(pane:))),
            hangup: ControlHangup()
        ) { answer.reply = $0 }
        return answer
    }

    private func waitOnChildren(_ mode: WaitChildren, from caller: Int?, timeout: Int? = nil) -> Answer {
        request(.paneWait, ControlArgs(timeout: timeout, children: mode), from: caller)
    }

    private func run(_ cmd: String, task: String? = nil, from caller: Int) throws -> RecordingSurface {
        let answer = request(.paneRun, ControlArgs(cmd: cmd, task: task, split: .right), from: caller)
        if task == nil { XCTAssertNotNil(answer.reply, "pane.run did not answer at once") }
        return try XCTUnwrap(spawned.last)
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
        surface.delegate?.surface(surface, programStatusDidChange: TerminalProgramStatus(state: state, app: "claude"))
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func news(_ got: WaitResult) -> [Int: WaitReason?] {
        Dictionary(uniqueKeysWithValues: (got.children ?? []).map { ($0.pane.token, $0.reason) })
    }

    func test_anyAnswersOnTheFirstChildsNews_namingItAmongEveryChild() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let first = try run("claude", from: caller)
        let second = try run("claude", from: caller)
        report(.working, from: first)
        report(.working, from: second)
        let answer = waitOnChildren(.any, from: caller)
        settle(0.3)
        XCTAssertNil(answer.reply, "two working children hold the wait")

        report(.done, from: second)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .stopped)
        XCTAssertNil(got.pane)
        XCTAssertEqual(news(got), [try token(of: first): nil, try token(of: second): .stopped])
        XCTAssertEqual(got.children?.first { $0.reason != nil }?.pane.agent?.status, .done)
        XCTAssertTrue(waits.pending.isEmpty)
        XCTAssertTrue(waits.childrenWaits.isEmpty)
    }

    func test_allHoldsUntilNoChildIsWorking() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let first = try run("claude", from: caller)
        let second = try run("claude", from: caller)
        report(.working, from: first)
        report(.working, from: second)
        let answer = waitOnChildren(.all, from: caller)

        report(.done, from: first)
        settle(0.6)
        XCTAssertNil(answer.reply, "one child still works")

        report(.blocked(.permission), from: second)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .stopped)
        XCTAssertEqual(news(got), [try token(of: first): .stopped, try token(of: second): .stopped])
    }

    func test_allAnswersAtOnceWhenNoChildIsWorking() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let child = try run("claude", from: caller)
        report(.idle, from: child)

        let got = try result(waitOnChildren(.all, from: caller))

        XCTAssertEqual(got.reason, .stopped)
        XCTAssertEqual(news(got), [try token(of: child): nil])
    }

    func test_aChildWhoseFirstTaskWasSentCountsAsWorkingUntilItsStatusMovesOn() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let child = try run("claude", task: "review x.swift", from: caller)
        report(.idle, from: child)
        XCTAssertEqual(child.pastes, ["review x.swift"])
        let answer = waitOnChildren(.all, from: caller)
        settle(0.6)
        XCTAssertNil(answer.reply, "an idle child with its task just sent answered as finished")

        report(.idle, from: child)
        report(.working, from: child)
        settle(0.6)
        XCTAssertNil(answer.reply)

        report(.done, from: child)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .stopped)
        XCTAssertEqual(news(got), [try token(of: child): .stopped])
    }

    func test_anIdleChildSentAFollowUpCountsAsWorkingUntilItsStatusMovesOn() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let child = try run("claude", from: caller)
        report(.idle, from: child)
        let sent = request(
            .paneSend, ControlArgs(pane: .token(try token(of: child)), text: "now fix y.swift", enter: true),
            from: caller)
        waitUntil(sent.reply != nil, "the send to answer")
        XCTAssertEqual(child.inputs.last, .submit)
        let answer = waitOnChildren(.all, from: caller)
        settle(0.6)
        XCTAssertNil(answer.reply, "an idle child with a follow-up just sent answered as finished")

        report(.idle, from: child)
        report(.working, from: child)
        settle(0.6)
        XCTAssertNil(answer.reply)

        report(.done, from: child)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .stopped)
        XCTAssertEqual(news(got), [try token(of: child): .stopped])
    }

    private func sendFollowUp(_ text: String, to child: RecordingSurface, from caller: Int) throws {
        let sent = request(
            .paneSend, ControlArgs(pane: .token(try token(of: child)), text: text, enter: true), from: caller)
        waitUntil(sent.reply != nil, "the send to answer")
        XCTAssertEqual(child.inputs.last, .submit)
    }

    func test_anIdleChildSentASlashCommandStaysFinished_sinceACommandStartsNoTurn() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let child = try run("claude", from: caller)
        report(.idle, from: child)
        try sendFollowUp("/clear", to: child, from: caller)

        let got = try result(waitOnChildren(.all, from: caller))

        XCTAssertEqual(got.reason, .stopped)
        XCTAssertEqual(news(got), [try token(of: child): nil])
    }

    func test_aChildWhoseAgentExitsBeforePickingUpAFollowUpStopsCountingAsWorking() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let child = try run("claude", from: caller)
        report(.idle, from: child)
        try sendFollowUp("now fix y.swift", to: child, from: caller)

        child.delegate?.surface(child, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        settle(0.1)

        let got = try result(waitOnChildren(.all, from: caller))
        XCTAssertEqual(got.reason, .stopped)
    }

    func test_aCallerWithNoChildrenHearsSoAtOnce() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))

        let got = try result(waitOnChildren(.all, from: caller))

        XCTAssertEqual(got.reason, .noChildren)
        XCTAssertEqual(got.children, [])
        XCTAssertTrue(waits.childrenWaits.isEmpty)
    }

    func test_aChildrenWaitNeedsACallerPane_noPane_andNoOutputWithAll() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let cases: [(Answer, ControlErrorCode)] = [
            (waitOnChildren(.any, from: nil), .badRequest),
            (waitOnChildren(.any, from: 9999), .notFound),
            (request(.paneWait, ControlArgs(pane: .token(caller), children: .any), from: caller), .badRequest),
            (request(.paneWait, ControlArgs(output: "ready", children: .all), from: caller), .badRequest),
        ]
        for (answer, code) in cases {
            guard case .failure(let error) = answer.reply else {
                return XCTFail("expected \(code), got \(answer.reply as Any)")
            }
            XCTAssertEqual(error.code, code, error.message)
        }
    }

    func test_aTextSentToTheCallerAnswersAChildrenWaitWithMessage() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let child = try run("claude", from: caller)
        report(.working, from: child)
        let answer = waitOnChildren(.all, from: caller)

        _ = request(.paneSend, ControlArgs(pane: .token(caller), text: "done: 2 bugs"), from: try token(of: child))

        let got = try result(answer)
        XCTAssertEqual(got.reason, .message)
        XCTAssertEqual(news(got), [try token(of: child): nil])
    }

    func test_aLaunchedPaneThatExitsWhileWaitedOnAnswersWithItsExitCodeAndLastLines() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let child = try run("npm test", from: caller)
        let answer = request(.paneWait, ControlArgs(pane: .token(try token(of: child))), from: caller)
        child.rows = []
        child.scrollback = ["$ npm test", "FAIL x.test.ts"]

        child.delegate?.surface(child, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 1))
        child.delegate?.surfaceDidExit(child, code: 0)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 3)
        XCTAssertEqual(got.text, "$ npm test\nFAIL x.test.ts")
        XCTAssertEqual(got.pane?.token, try token(of: child))
    }

    func test_aLaunchedPaneWhoseExitMarkTrailsItsExitStillAnswersWithItsExitCode() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let child = try run("npm test", from: caller)
        let answer = request(.paneWait, ControlArgs(pane: .token(try token(of: child))), from: caller)

        child.delegate?.surfaceDidExit(child, code: 0)
        child.delegate?.surface(child, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 1))

        let got = try result(answer)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 3)
    }

    func test_aWaitThatBeginsAfterALaunchedPaneClosedAnswersWithItsExit() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let named = request(.paneRun, ControlArgs(cmd: "npm test", name: "tests", split: .right), from: caller)
        XCTAssertNotNil(named.reply)
        let child = try XCTUnwrap(spawned.last)
        let token = try token(of: child)
        child.title = "npm test"
        child.rows = []
        child.scrollback = ["$ npm test", "FAIL x.test.ts"]
        child.delegate?.surface(child, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 1))
        child.delegate?.surfaceDidExit(child, code: 0)
        settle(0.1)

        let got = try result(request(.paneWait, ControlArgs(pane: .token(token)), from: caller))

        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 3)
        XCTAssertEqual(got.text, "$ npm test\nFAIL x.test.ts")
        XCTAssertEqual(got.pane?.token, token)
        XCTAssertEqual(got.pane?.name, "tests")
        XCTAssertEqual(got.pane?.title, "npm test")
        XCTAssertTrue(waits.pending.isEmpty)
    }

    func test_aWaitByNameThatBeginsAfterItsPaneClosedAnswersWithTheLatestExitOfThatName() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        var tokens: [Int] = []
        for code in [3, 5] {
            let ran = request(.paneRun, ControlArgs(cmd: "npm test", name: "tests", split: .right), from: caller)
            XCTAssertNotNil(ran.reply)
            let child = try XCTUnwrap(spawned.last)
            tokens.append(try token(of: child))
            child.delegate?.surface(child, commandDidFinish: TerminalCommandResult(exitCode: code, duration: 1))
            child.delegate?.surfaceDidExit(child, code: 0)
            settle(0.1)
        }

        let got = try result(request(.paneWait, ControlArgs(pane: .name("tests")), from: caller))

        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 5)
        XCTAssertEqual(got.pane?.token, tokens.last)
        XCTAssertEqual(got.pane?.name, "tests")
    }

    func test_anyHearsALaunchedChildExit_withItsExitCode() throws {
        makeWindow()
        let caller = try token(of: try XCTUnwrap(spawned.first))
        let agent = try run("claude", from: caller)
        report(.working, from: agent)
        let tests = try run("npm test", from: caller)
        let answer = waitOnChildren(.any, from: caller)

        tests.delegate?.surface(tests, commandDidFinish: TerminalCommandResult(exitCode: 1, duration: 1))
        tests.delegate?.surfaceDidExit(tests, code: 0)

        let got = try result(answer)
        XCTAssertEqual(got.reason, .exited)
        let exited = try XCTUnwrap(got.children?.first { $0.reason == .exited })
        XCTAssertEqual(exited.pane.token, try token(of: tests))
        XCTAssertEqual(exited.exitCode, 1)
    }
}
