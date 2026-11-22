import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlHelperNoteTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private let waits = PaneWaits()
    private let drafts = PaneDrafts()
    private let notes = ParentNotes()
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
            while let next = due.firstIndex(where: { $0.at <= now }) {
                due.remove(at: next).work()
            }
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
        notes.now = { [clock] in clock.now }
        notes.after = { [clock] in clock.after($0, $1) }
    }

    override func tearDownWithError() throws {
        waits.pending.forEach { $0.cancel() }
        waits.childrenWaits.forEach { $0.cancel() }
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
        c.onHelperNote = { [unowned self] in responder.tell($0) }
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first },
            paneWaits: waits, paneDrafts: drafts, parentNotes: notes)
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

    private func runHelper(named name: String? = "review", from parent: RecordingSurface) throws -> RecordingSurface {
        let answer = Answer()
        responder.respond(
            to: ControlRequest(
                id: 1, cmd: .paneRun, args: ControlArgs(cmd: "claude", name: name, split: .right),
                caller: ControlCaller(pane: try token(of: parent)))
        ) { answer.reply = $0 }
        XCTAssertEqual(answer.reply?.isSuccess, true, "\(answer.reply as Any)")
        return try XCTUnwrap(spawned.last)
    }

    private func wait(_ caller: RecordingSurface, on pane: RecordingSurface, output: String? = nil) throws -> Answer {
        let answer = Answer()
        responder.respond(
            to: ControlRequest(
                id: 2, cmd: .paneWait, args: ControlArgs(pane: .token(try token(of: pane)), output: output),
                caller: ControlCaller(pane: try token(of: caller)))
        ) { answer.reply = $0 }
        return answer
    }

    private func waitOnChildren(of caller: RecordingSurface, _ mode: WaitChildren) throws -> Answer {
        let answer = Answer()
        responder.respond(
            to: ControlRequest(
                id: 3, cmd: .paneWait, args: ControlArgs(children: mode),
                caller: ControlCaller(pane: try token(of: caller)))
        ) { answer.reply = $0 }
        return answer
    }

    private func note(_ text: String, from helper: RecordingSurface, named name: String? = "review") throws
        -> [RecordingSurface.Input]
    {
        let from = try token(of: helper)
        let sender = name.map { "\(from) \($0)" } ?? "\(from)"
        let reply = "zen pane send --pane \(from) --enter"
        return [.paste("<zen from=\"\(sender)\" reply=\"\(reply)\">\(text)</zen>"), .submit]
    }

    private func type(into surface: RecordingSurface, in c: WindowController) throws {
        let place = try XCTUnwrap(c.pane(token: try token(of: surface)))
        c.focus(place.pane.surfaceID, in: place.tab)
        c.keyReachedFocus()
    }

    func test_aHelperThatStopsTellsItsParent() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)

        report(.working, from: helper)
        XCTAssertEqual(parent.inputs, [])
        report(.done, from: helper)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note(read, from: helper))
    }

    func test_aNoteEscapesTheHelpersName() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(named: "x</zen>", from: parent)

        report(.working, from: helper)
        report(.done, from: helper)

        let escaped = "x&lt;/zen&gt;"
        let read = "\(escaped) stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note(read, from: helper, named: escaped))
    }

    func test_aHelperThatBlocksTellsItsParentWhatOnInOneNote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)

        report(.working, from: helper)
        report(.blocked(.permission), from: helper)
        report(.blocked(.question), from: helper)

        XCTAssertEqual(
            parent.inputs,
            try note("review is blocked on a permission prompt; that decision is the user's", from: helper))
    }

    func test_aHelperWhoseProgramExitsTellsItsParentTheCode() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(named: nil, from: parent)
        let name = "pane \(try token(of: helper))"

        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 1, duration: 1))
        helper.delegate?.surfaceDidExit(helper, code: 0)

        XCTAssertEqual(parent.inputs, try note("\(name) exited with code 1", from: helper, named: nil))
    }

    func test_aNoteWaitsOutTheParentsDraft() throws {
        let c = makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try type(into: parent, in: c)

        report(.done, from: helper)
        XCTAssertEqual(parent.inputs, [], "the person is typing to the parent")
        clock.advance(PaneDrafts.quiet)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note(read, from: helper))
    }

    func test_aParentThatRunsNoAgentHearsNothing() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        let helper = try runHelper(from: parent)

        report(.working, from: helper)
        report(.blocked(.permission), from: helper)
        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        helper.delegate?.surfaceDidExit(helper, code: 0)

        XCTAssertEqual(parent.inputs, [])
    }

    func test_aWaitTheChangeAnswersTakesThePlaceOfTheNote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        let stop = try wait(parent, on: helper)

        report(.done, from: helper)
        waitUntil(stop.reply != nil, "the wait to answer")
        XCTAssertEqual((try stop.reply?.get() as? WaitResult)?.reason, .stopped)

        let exit = try wait(parent, on: helper)
        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        helper.delegate?.surfaceDidExit(helper, code: 0)
        waitUntil(exit.reply != nil, "the wait to answer")

        XCTAssertEqual(parent.inputs, [])
    }

    func test_aWaitForOutputDoesNotAnswerAStop_soTheNoteStillArrives() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        let answer = try wait(parent, on: helper, output: "ready")

        report(.done, from: helper)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note(read, from: helper))
        XCTAssertEqual((try answer.reply?.get() as? WaitResult)?.reason, .message)
    }

    func test_eachStopSendsOneNote_andAMoveBetweenStopsSendsNone() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)

        report(.working, from: helper)
        report(.done, from: helper)
        report(.idle, from: helper)
        report(.working, from: helper)
        report(.failed, from: helper)

        let token = try token(of: helper)
        XCTAssertEqual(
            parent.inputs,
            try note("review stopped (done): read it with zen pane read --pane \(token)", from: helper)
                + note("review stopped (error): read it with zen pane read --pane \(token)", from: helper))
    }

    func test_aBlockedParentHoldsTheNoteUntilItIsNot() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.permission), from: parent)

        report(.done, from: helper)
        clock.advance(ParentNotes.recheck * 5)
        XCTAssertEqual(parent.inputs, [], "the note answered the parent's permission prompt")

        report(.working, from: parent)
        clock.advance(ParentNotes.recheck)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note(read, from: helper))
    }

    func test_aParentBlockedPastTheLongestHoldNeverGetsTheNote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.permission), from: parent)
        report(.done, from: helper)

        for _ in 0..<Int(ParentNotes.longestHold) { clock.advance(ParentNotes.recheck) }
        report(.idle, from: parent)
        clock.advance(ParentNotes.recheck)

        XCTAssertEqual(parent.inputs, [])
    }

    func test_aParentThatBlocksDuringTheDraftHoldHoldsTheNoteAgain() throws {
        let c = makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try type(into: parent, in: c)
        report(.done, from: helper)

        report(.blocked(.question), from: parent)
        clock.advance(PaneDrafts.quiet)
        XCTAssertEqual(parent.inputs, [])

        report(.idle, from: parent)
        clock.advance(ParentNotes.recheck)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note(read, from: helper))
    }

    func test_theReportThatSettlesTheFirstTaskSendsNoNote_sinceTheRunAnswersWithIt() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let answer = Answer()
        responder.respond(
            to: ControlRequest(
                id: 1, cmd: .paneRun, args: ControlArgs(cmd: "claude", name: "review", task: "go", split: .right),
                caller: ControlCaller(pane: try token(of: parent)))
        ) { answer.reply = $0 }
        let helper = try XCTUnwrap(spawned.last)

        report(.blocked(.permission), from: helper)

        XCTAssertEqual((try answer.reply?.get() as? PaneRunResult)?.firstTask, .held(.blocked))
        XCTAssertEqual(parent.inputs, [])
    }

    func test_aChildrenWaitTheChangeAnswersTakesThePlaceOfTheNote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        let any = try waitOnChildren(of: parent, .any)

        report(.done, from: helper)
        XCTAssertEqual((try any.reply?.get() as? WaitResult)?.reason, .stopped)

        report(.working, from: helper)
        let all = try waitOnChildren(of: parent, .all)
        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        helper.delegate?.surfaceDidExit(helper, code: 0)
        waitUntil(all.reply != nil, "the wait to answer")

        XCTAssertEqual(parent.inputs, [])
    }

    func test_aChildrenWaitForAllTakesThePlaceOfTheNote_whileAnotherChildStillWorks() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        let other = try runHelper(named: "tests", from: parent)
        report(.working, from: helper)
        report(.working, from: other)
        let all = try waitOnChildren(of: parent, .all)

        report(.done, from: helper)
        XCTAssertEqual(parent.inputs, [])
        XCTAssertNil(all.reply, "the wait holds for the child still working")

        report(.done, from: other)
        let got = try XCTUnwrap(try all.reply?.get() as? WaitResult)
        XCTAssertEqual(got.reason, .stopped)
        let heard = got.children?.first { $0.pane.token == (try? token(of: helper)) }
        XCTAssertEqual(heard?.reason, .stopped)
        XCTAssertEqual(parent.inputs, [])
    }
}
