import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlPaneSendTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private let waits = PaneWaits()
    private let drafts = PaneDrafts()
    private let clock = Clock()
    private let originalPresence = WindowController.isPresent

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        private var due: [(at: Date, work: () -> Void)] = []

        func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            due.append((now.addingTimeInterval(delay), work))
        }

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            let ready = due.filter { $0.at <= now }
            due.removeAll { $0.at <= now }
            ready.forEach { $0.work() }
        }
    }

    private final class Answer {
        var reply: ControlReply?
    }

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
        drafts.now = { [clock] in clock.now }
        drafts.after = { [clock] in clock.after($0, $1) }
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
        c.paneDrafts = drafts
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first },
            paneWaits: waits, paneDrafts: drafts)
    }

    private func send(
        _ text: String, to pane: Int, from caller: Int? = nil, enter: Bool? = nil, force: Bool? = nil,
        wait: Bool? = nil, timeout: Int? = nil, hangup: ControlHangup = ControlHangup()
    ) -> Answer {
        let answer = Answer()
        let args = ControlArgs(force: force, pane: pane, text: text, enter: enter, timeout: timeout, wait: wait)
        responder.respond(
            to: ControlRequest(id: 1, cmd: .paneSend, args: args, caller: caller.map(ControlCaller.init(pane:))),
            hangup: hangup
        ) { answer.reply = $0 }
        return answer
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

    private func split(_ c: WindowController, from surface: RecordingSurface) throws -> RecordingSurface {
        responder.respond(
            to: ControlRequest(id: 2, cmd: .paneSplit, args: ControlArgs(pane: try token(of: surface), dir: .right))
        ) { _ in }
        return try XCTUnwrap(spawned.last)
    }

    private func type(into surface: RecordingSurface, in c: WindowController) throws {
        let place = try XCTUnwrap(c.pane(token: try token(of: surface)))
        c.focus(place.pane.surfaceID, in: place.tab)
        c.keyReachedFocus()
    }

    func test_aBlockedAgentRefusesTheSend_andForceSendsIt() throws {
        makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.blocked(.permission), from: agent)

        guard case .failure(let refusal) = send("yes", to: try token(of: agent), enter: true).reply else {
            return XCTFail("a blocked agent took the send")
        }
        XCTAssertEqual(refusal.code, .refused)
        XCTAssertTrue(refusal.message.contains("decision is the user's"), refusal.message)
        XCTAssertEqual(agent.inputs, [])

        XCTAssertEqual(send("yes", to: try token(of: agent), enter: true, force: true).reply?.isSuccess, true)
        XCTAssertEqual(agent.inputs, [.paste("yes"), .submit])
    }

    func test_aWorkingAgentTakesTheSend() throws {
        makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.working, from: agent)

        XCTAssertEqual(send("and the tests", to: try token(of: agent)).reply?.isSuccess, true)
        XCTAssertEqual(agent.inputs, [.paste("and the tests")])
    }

    func test_aSendWaitsForTheDraftToGoQuietForTwoSeconds() throws {
        let c = makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.idle, from: agent)
        try type(into: agent, in: c)

        let answer = send("review x.swift", to: try token(of: agent))
        XCTAssertNil(answer.reply, "the person is typing")
        clock.advance(1)
        try type(into: agent, in: c)
        clock.advance(1.5)
        XCTAssertNil(answer.reply, "a key a second in restarts the quiet window")
        XCTAssertEqual(agent.inputs, [])

        clock.advance(0.5)

        XCTAssertEqual(answer.reply?.isSuccess, true)
        XCTAssertEqual(agent.inputs, [.paste("review x.swift")])
    }

    func test_aDraftThatNeverGoesQuietHoldsTheSendForAtMostSixtySeconds() throws {
        let c = makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.idle, from: agent)
        try type(into: agent, in: c)
        let answer = send("review x.swift", to: try token(of: agent))

        for _ in 0..<59 {
            clock.advance(1)
            try type(into: agent, in: c)
        }
        XCTAssertNil(answer.reply)

        clock.advance(1)

        XCTAssertEqual(answer.reply?.isSuccess, true)
        XCTAssertEqual(agent.inputs, [.paste("review x.swift")])
    }

    func test_aKeyLongEnoughAgoHoldsNothing_andAShellIsNeverHeld() throws {
        let c = makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        let shell = try split(c, from: agent)
        report(.idle, from: agent)
        try type(into: agent, in: c)
        try type(into: shell, in: c)
        clock.advance(PaneDrafts.quiet)

        XCTAssertEqual(send("go", to: try token(of: agent)).reply?.isSuccess, true)
        try type(into: shell, in: c)
        XCTAssertEqual(send("ls", to: try token(of: shell)).reply?.isSuccess, true)
        XCTAssertEqual(shell.inputs, [.paste("ls")])
    }

    func test_anAgentThatBlocksDuringTheHoldRefusesWhenItEnds() throws {
        let c = makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.working, from: agent)
        try type(into: agent, in: c)
        let answer = send("go", to: try token(of: agent))

        report(.blocked(.question), from: agent)
        clock.advance(PaneDrafts.quiet)

        guard case .failure(let refusal) = answer.reply else { return XCTFail("\(answer.reply as Any)") }
        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(agent.inputs, [])
    }

    func test_aHangupDuringTheHoldDropsTheSend() throws {
        let c = makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.idle, from: agent)
        try type(into: agent, in: c)
        let hangup = ControlHangup()
        let answer = send("go", to: try token(of: agent), hangup: hangup)

        hangup.hangUp()
        clock.advance(PaneDrafts.quiet)

        XCTAssertNil(answer.reply)
        XCTAssertEqual(agent.inputs, [])
    }

    func test_anAgentsMessageToAnotherAgentArrivesInAnEnvelope_andOneToAShellDoesNot() throws {
        let c = makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        let helper = try split(c, from: parent)
        let shell = try split(c, from: helper)
        report(.idle, from: helper)
        let from = try token(of: parent)

        XCTAssertEqual(send("2 bugs", to: try token(of: helper), from: from, enter: true).reply?.isSuccess, true)
        XCTAssertEqual(send("ls", to: try token(of: shell), from: from).reply?.isSuccess, true)
        XCTAssertEqual(send("from the user", to: try token(of: helper)).reply?.isSuccess, true)

        XCTAssertEqual(
            helper.inputs,
            [
                .paste("<zen from=\"\(from)\" reply=\"zen pane send --pane \(from)\">2 bugs</zen>"), .submit,
                .paste("from the user"),
            ])
        XCTAssertEqual(shell.inputs, [.paste("ls")])
    }

    func test_waitSendsThenAnswersAsPaneWaitOnTheTarget() throws {
        makeWindow()
        let agent = try XCTUnwrap(spawned.first)
        report(.idle, from: agent)

        let answer = send("review x.swift", to: try token(of: agent), enter: true, wait: true)
        XCTAssertEqual(agent.inputs, [.paste("review x.swift"), .submit])
        XCTAssertNil(answer.reply, "the wait holds until the agent's turn ends")
        XCTAssertEqual(waits.pending.count, 1)

        report(.working, from: agent)
        report(.done, from: agent)

        waitUntil(answer.reply != nil, "the wait to answer")
        let got = try XCTUnwrap(try answer.reply?.get() as? WaitResult)
        XCTAssertEqual(got.reason, .stopped)
        XCTAssertEqual(got.pane.token, try token(of: agent))
    }

    func test_waitTakesATimeoutInRange() throws {
        makeWindow()
        let pane = try token(of: try XCTUnwrap(spawned.first))

        guard case .failure(let error) = send("ls", to: pane, wait: true, timeout: 0).reply else {
            return XCTFail("a timeout of 0 was accepted")
        }
        XCTAssertEqual(error.code, .badRequest)
        XCTAssertEqual(spawned.first?.inputs, [])
    }
}
