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
            paneWaits: waits, paneDrafts: drafts)
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

    private func send(_ text: String, from sender: RecordingSurface, to pane: RecordingSurface, enter: Bool = true)
        throws
    {
        let reply = try sending(text, from: sender, to: pane, enter: enter)
        XCTAssertEqual(reply?.isSuccess, true, "\(reply as Any)")
    }

    private func sending(
        _ text: String, from sender: RecordingSurface, to pane: RecordingSurface, enter: Bool = true
    ) throws -> ControlReply? {
        let answer = Answer()
        responder.respond(
            to: ControlRequest(
                id: 4, cmd: .paneSend, args: ControlArgs(pane: .token(try token(of: pane)), text: text, enter: enter),
                caller: ControlCaller(pane: try token(of: sender)))
        ) { answer.reply = $0 }
        return answer.reply
    }

    private func pressing(
        _ keys: [String], from sender: RecordingSurface, to pane: RecordingSurface, force: Bool? = nil
    ) throws -> ControlReply? {
        let answer = Answer()
        responder.respond(
            to: ControlRequest(
                id: 6, cmd: .paneKeys, args: ControlArgs(force: force, pane: .token(try token(of: pane)), keys: keys),
                caller: ControlCaller(pane: try token(of: sender)))
        ) { answer.reply = $0 }
        return answer.reply
    }

    private static func pressed(_ names: [String]) throws -> [RecordingSurface.Input] {
        try names.map { .press(try XCTUnwrap(PaneKey(name: $0).flatMap(TerminalKey.init(paneKey:)))) }
    }

    private static func errorCode(of reply: ControlReply?) -> ControlErrorCode? {
        guard case .failure(let error) = reply else { return nil }
        return error.code
    }

    private func close(_ pane: RecordingSurface, by caller: RecordingSurface) throws {
        let answer = Answer()
        responder.respond(
            to: ControlRequest(
                id: 5, cmd: .paneClose, args: ControlArgs(force: true, pane: .token(try token(of: pane))),
                caller: ControlCaller(pane: try token(of: caller)))
        ) { answer.reply = $0 }
        XCTAssertEqual(answer.reply?.isSuccess, true, "\(answer.reply as Any)")
    }

    private func type(into surface: RecordingSurface, in c: WindowController) throws {
        let place = try XCTUnwrap(c.pane(token: try token(of: surface)))
        c.focus(place.pane.surfaceID, in: place.tab)
        try sendKeys(typing: "draft", to: c)
    }

    private func sendDraft(in c: WindowController) throws {
        try sendKeys([.returnKey], to: c)
        clock.advance(0)
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
        clock.advance(PaneDrafts.draftWait - 1)
        XCTAssertEqual(parent.inputs, [], "the person has an unsent draft in the parent")
        try sendDraft(in: c)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note(read, from: helper))
    }

    func test_aNoteSetsAsideAParentsDraftLeftAMinute() throws {
        let c = makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try type(into: parent, in: c)

        report(.done, from: helper)
        clock.advance(PaneDrafts.draftWait)

        let stash = try XCTUnwrap(TerminalKey(chord: Chord(control: true, key: "s")))
        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, [.press(stash)] + (try note(read, from: helper)))
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

    func test_aWaitThatAnsweredTheExitBeforeThePaneClosedTakesThePlaceOfTheNote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        let exit = try wait(parent, on: helper)

        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 1, duration: 1))
        waitUntil(exit.reply != nil, "the wait to answer the exit mark")
        helper.delegate?.surfaceDidExit(helper, code: 0)

        XCTAssertEqual((try exit.reply?.get() as? WaitResult)?.reason, .exited)
        XCTAssertEqual(parent.inputs, [])
    }

    func test_aChildrenWaitThatAnsweredTheExitBeforeThePaneClosedTakesThePlaceOfTheNote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        let any = try waitOnChildren(of: parent, .any)

        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 1, duration: 1))
        waitUntil(any.reply != nil, "the wait to answer the exit mark")
        helper.delegate?.surfaceDidExit(helper, code: 0)

        XCTAssertEqual((try any.reply?.get() as? WaitResult)?.reason, .exited)
        XCTAssertEqual(parent.inputs, [])
    }

    func test_anotherHelpersNoteReachesTheParentButLeavesItsWaitOnAHelperStanding() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        let other = try runHelper(named: "tests", from: parent)
        report(.working, from: helper)
        report(.working, from: other)
        let answer = try wait(parent, on: helper)

        report(.done, from: other)

        let read = "tests stopped (done): read it with zen pane read --pane \(try token(of: other))"
        XCTAssertEqual(parent.inputs, try note(read, from: other, named: "tests"))
        XCTAssertNil(answer.reply)
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
        clock.advance(PaneDrafts.blockedRecheck * 5)
        XCTAssertEqual(parent.inputs, [], "the note answered the parent's permission prompt")

        report(.working, from: parent)
        clock.advance(PaneDrafts.blockedRecheck)

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

        for _ in 0..<Int(PaneDrafts.longestBlockedHold) { clock.advance(PaneDrafts.blockedRecheck) }
        report(.idle, from: parent)
        clock.advance(PaneDrafts.blockedRecheck)

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

        try sendKeys([.controlU], to: c)
        report(.blocked(.question), from: parent)
        clock.advance(PaneDrafts.quiet)
        XCTAssertEqual(parent.inputs, [])

        report(.idle, from: parent)
        clock.advance(PaneDrafts.blockedRecheck)

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

    func test_aChildrenWaitForAllKeepsWatchingAStoppedChild_soItsExitIsRecordedNotLost() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        let other = try runHelper(named: "tests", from: parent)
        report(.working, from: helper)
        report(.working, from: other)
        let all = try waitOnChildren(of: parent, .all)
        report(.done, from: helper)
        helper.scrollback = ["review: 2 bugs"]

        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 1))
        helper.delegate?.surfaceDidExit(helper, code: 0)
        XCTAssertEqual(parent.inputs, [])
        report(.done, from: other)

        let got = try XCTUnwrap(try all.reply?.get() as? WaitResult)
        XCTAssertEqual(got.reason, .stopped)
        let heard = try XCTUnwrap(got.children?.first { $0.pane.token == (try? token(of: helper)) })
        XCTAssertEqual(heard.reason, .exited)
        XCTAssertEqual(heard.exitCode, 3)
        XCTAssertTrue(heard.text?.hasPrefix("review: 2 bugs") == true, "\(String(describing: heard.text))")
        XCTAssertEqual(parent.inputs, [])
    }

    func test_aHelperThatReportedToItsParentStopsWithoutANote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)

        report(.working, from: helper)
        try send("2 bugs", from: helper, to: parent)
        report(.working, from: helper)
        report(.done, from: helper)

        XCTAssertEqual(parent.inputs, try note("2 bugs", from: helper))
    }

    func test_anUnsubmittedPasteOrKeysToTheParentIsNotAReport() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try send("2 bugs", from: helper, to: parent, enter: false)
        XCTAssertEqual(try pressing(["space"], from: helper, to: parent)?.isSuccess, true)
        let before = parent.inputs

        report(.done, from: helper)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(Array(parent.inputs.dropFirst(before.count)), try note(read, from: helper))
    }

    func test_aReportCountsOnlyUntilTheHelpersNextTurn() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try send("2 bugs", from: helper, to: parent)
        report(.done, from: helper)

        report(.working, from: helper)
        report(.done, from: helper)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note("2 bugs", from: helper) + note(read, from: helper))
    }

    func test_aMessageToAnotherPaneIsNotAReport() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        let sibling = try runHelper(named: "tests", from: parent)
        report(.working, from: helper)
        try send("go", from: helper, to: sibling)

        report(.done, from: helper)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note(read, from: helper))
    }

    func test_aReportStillLetsABlockedNoteThrough() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try send("2 bugs", from: helper, to: parent)

        report(.blocked(.permission), from: helper)

        XCTAssertEqual(
            parent.inputs,
            try note("2 bugs", from: helper)
                + note("review is blocked on a permission prompt; that decision is the user's", from: helper))
    }

    func test_aChildrenWaitForAnyAnswersOnTheTurnOfATaskQueuedForTheChildsDraft() throws {
        try assertChildrenWaitAnswersOnTheQueuedTasksTurn(.any)
    }

    func test_aChildrenWaitForAllAnswersOnTheTurnOfATaskQueuedForTheChildsDraft() throws {
        try assertChildrenWaitAnswersOnTheQueuedTasksTurn(.all)
    }

    private func assertChildrenWaitAnswersOnTheQueuedTasksTurn(_ mode: WaitChildren) throws {
        let c = makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try type(into: helper, in: c)
        let queued = try XCTUnwrap(try sending("go", from: parent, to: helper)?.get() as? PaneSendResult)
        XCTAssertEqual(queued.queued, true)
        let answer = try waitOnChildren(of: parent, mode)

        report(.done, from: helper)
        XCTAssertNil(answer.reply, "the turn that ended is not the queued task's")
        XCTAssertEqual(parent.inputs, [], "a helper with a task queued for it has not stopped")

        try sendDraft(in: c)
        report(.working, from: helper)
        report(.done, from: helper)
        waitUntil(answer.reply != nil, "the wait to answer")
        let got = try XCTUnwrap(try answer.reply?.get() as? WaitResult)
        XCTAssertEqual(got.reason, .stopped)
    }

    func test_aParentThatClosesItsHelperDropsTheNoteHeldForItsDraft() throws {
        let c = makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try type(into: parent, in: c)
        report(.done, from: helper)

        try close(helper, by: parent)
        try sendDraft(in: c)

        XCTAssertEqual(parent.inputs, [])
    }

    func test_aParentThatClosesItsHelperDropsTheNoteHeldWhileItIsBlocked() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.permission), from: parent)
        report(.blocked(.question), from: helper)

        try close(helper, by: parent)
        report(.working, from: parent)
        clock.advance(PaneDrafts.blockedRecheck)

        XCTAssertEqual(parent.inputs, [])
    }

    func test_anExitNoteHeldForTheParentsDraftStillArrivesOnceThePaneHasClosed() throws {
        let c = makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(named: nil, from: parent)
        let name = "pane \(try token(of: helper))"
        try type(into: parent, in: c)

        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 1, duration: 1))
        helper.delegate?.surfaceDidExit(helper, code: 0)
        XCTAssertEqual(parent.inputs, [])
        try sendDraft(in: c)

        XCTAssertEqual(parent.inputs, try note("\(name) exited with code 1", from: helper, named: nil))
    }

    func test_aHelperBlockedOnAQuestionTellsItsParentToAnswerIt() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)

        report(.blocked(.question), from: helper)

        let token = try token(of: helper)
        let ask =
            "review is asking a question: read it with zen pane read --pane \(token) and answer it, "
            + "or ask the user when it is a product or scope call"
        XCTAssertEqual(parent.inputs, try note(ask, from: helper))
    }

    func test_aParentAnswersItsHelpersQuestion() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.question), from: helper)

        try send("use the staging bucket", from: parent, to: helper)

        let from = try token(of: parent)
        let reply = "zen pane send --pane \(from) --enter"
        XCTAssertEqual(
            helper.inputs.suffix(2),
            [.paste("<zen from=\"\(from)\" reply=\"\(reply)\">use the staging bucket</zen>"), .submit])
    }

    func test_aHelpersQuestionIsNotAnotherPanesToAnswer() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        let helper = try runHelper(from: parent)
        let sibling = try runHelper(named: "tests", from: parent)
        report(.working, from: helper)
        report(.blocked(.question), from: helper)

        let reply = try sending("yes", from: sibling, to: helper)

        XCTAssertEqual(Self.errorCode(of: reply), .refused)
    }

    func test_aHelpersPermissionPromptOrLoginStaysTheUsers_evenForItsParent() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)

        for need in [TerminalProgramStatus.Need.permission, .auth] {
            report(.blocked(need), from: helper)
            XCTAssertEqual(Self.errorCode(of: try sending("yes", from: parent, to: helper)), .refused, "\(need)")
            report(.working, from: helper)
        }
    }

    func test_aHelpersReportToABlockedParentIsHeldPastTheLongestHold_untilTheParentIsFree() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.permission), from: parent)

        let reply = try sending("2 bugs", from: helper, to: parent)
        guard case .success(let payload) = reply else { return XCTFail("\(reply as Any)") }
        XCTAssertEqual((payload as? PaneSendResult)?.queued, true)
        for _ in 0...Int(PaneDrafts.longestBlockedHold) { clock.advance(PaneDrafts.blockedRecheck) }
        XCTAssertEqual(parent.inputs, [], "the report answered the parent's permission prompt")

        report(.working, from: parent)
        clock.advance(PaneDrafts.blockedRecheck)
        XCTAssertEqual(parent.inputs, try note("2 bugs", from: helper))
    }

    func test_aHelperWhoseReportIsHeldStopsWithoutASecondNote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.permission), from: parent)

        _ = try sending("2 bugs", from: helper, to: parent)
        report(.done, from: helper)
        report(.working, from: parent)
        clock.advance(PaneDrafts.blockedRecheck * 5)

        XCTAssertEqual(parent.inputs, try note("2 bugs", from: helper))
    }

    func test_aSendFromAnyoneButItsHelperIntoABlockedAgentIsRefused_withoutOfferingForce() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        let helper = try runHelper(from: parent)
        let sibling = try runHelper(named: "tests", from: parent)
        report(.blocked(.permission), from: helper)

        let reply = try sending("yes", from: sibling, to: helper)
        guard case .failure(let refusal) = reply else { return XCTFail("\(reply as Any)") }
        XCTAssertEqual(refusal.code, .refused)
        XCTAssertFalse(refusal.message.contains("--force"), refusal.message)
        XCTAssertEqual(helper.inputs, [])
    }

    func test_aHelperWhoseBlockClearsTellsItsParentToWaitAgain() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.permission), from: helper)

        report(.working, from: helper)
        report(.working, from: helper)

        let token = try token(of: helper)
        XCTAssertEqual(
            parent.inputs,
            try note("review is blocked on a permission prompt; that decision is the user's", from: helper)
                + note("review is working again; wait on it with zen wait \(token)", from: helper))
    }

    func test_aWaitTheParentHoldsOnTheHelperTakesThePlaceOfTheWorkingAgainNote() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        let blocked = try wait(parent, on: helper)
        report(.blocked(.permission), from: helper)
        XCTAssertEqual((try blocked.reply?.get() as? WaitResult)?.reason, .stopped)
        let resumed = try wait(parent, on: helper)

        report(.working, from: helper)

        XCTAssertEqual(parent.inputs, [])
        XCTAssertNil(resumed.reply, "the note answered the parent's wait")
    }

    func test_keysIntoAPermissionPromptOrLoginAreRefused_forItsParentAndAStranger_andForcePressesThem() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        let helper = try runHelper(from: parent)
        let stranger = try runHelper(named: "tests", from: parent)
        report(.working, from: helper)

        for need in [TerminalProgramStatus.Need.permission, .auth] {
            report(.blocked(need), from: helper)
            let before = helper.inputs
            for caller in [parent, stranger] {
                XCTAssertEqual(
                    Self.errorCode(of: try pressing(["enter"], from: caller, to: helper)), .refused, "\(need)")
            }
            XCTAssertEqual(helper.inputs, before, "\(need)")
            let forced = try pressing(["enter"], from: stranger, to: helper, force: true)
            XCTAssertEqual(forced?.isSuccess, true, "\(forced as Any)")
            XCTAssertEqual(helper.inputs, before + (try Self.pressed(["enter"])))
            report(.working, from: helper)
        }
    }

    func test_keysIntoAHelpersQuestionComeFromItsParent_andAreRefusedForAnyoneElse() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        let helper = try runHelper(from: parent)
        let stranger = try runHelper(named: "tests", from: parent)
        report(.working, from: helper)
        report(.blocked(.question), from: helper)
        let before = helper.inputs

        XCTAssertEqual(Self.errorCode(of: try pressing(["down"], from: stranger, to: helper)), .refused)
        XCTAssertEqual(helper.inputs, before)

        let answered = try pressing(["down", "enter"], from: parent, to: helper)
        XCTAssertEqual(answered?.isSuccess, true, "\(answered as Any)")
        XCTAssertEqual(helper.inputs, before + (try Self.pressed(["down", "enter"])))
    }

    func test_aReportHoldsThroughABlockInTheSameTurn() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try send("2 bugs", from: helper, to: parent)
        report(.blocked(.permission), from: helper)
        report(.working, from: helper)

        report(.done, from: helper)

        let token = try token(of: helper)
        XCTAssertEqual(
            parent.inputs,
            try note("2 bugs", from: helper)
                + note("review is blocked on a permission prompt; that decision is the user's", from: helper)
                + note("review is working again; wait on it with zen wait \(token)", from: helper))
    }

    func test_aQuestionToTheParentIsNotAReportOnceTheParentAnswersIt() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        try send("which bucket?", from: helper, to: parent)
        try send("staging", from: parent, to: helper)

        report(.done, from: helper)

        let read = "review stopped (done): read it with zen pane read --pane \(try token(of: helper))"
        XCTAssertEqual(parent.inputs, try note("which bucket?", from: helper) + note(read, from: helper))
    }

    func test_aParentThatAnswersItsHelpersQuestionHearsNoWorkingAgainNote_butALaterBlockStillTellsIt() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.question), from: helper)
        let token = try token(of: helper)
        let ask = try note(
            "review is asking a question: read it with zen pane read --pane \(token) and answer it, "
                + "or ask the user when it is a product or scope call", from: helper)
        try send("staging", from: parent, to: helper)

        report(.working, from: helper)
        XCTAssertEqual(parent.inputs, ask)

        report(.blocked(.permission), from: helper)
        report(.working, from: helper)
        XCTAssertEqual(
            parent.inputs,
            try ask + note("review is blocked on a permission prompt; that decision is the user's", from: helper)
                + note("review is working again; wait on it with zen wait \(token)", from: helper))
    }

    func test_aBlockedNoteHeldPastTheBlockIsDropped() throws {
        makeWindow()
        let parent = try XCTUnwrap(spawned.first)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.blocked(.permission), from: parent)
        report(.blocked(.permission), from: helper)
        report(.working, from: helper)

        report(.working, from: parent)
        clock.advance(PaneDrafts.blockedRecheck)

        let token = try token(of: helper)
        XCTAssertEqual(
            parent.inputs, try note("review is working again; wait on it with zen wait \(token)", from: helper))
    }

    func test_aNoteToAnIdleParentLeavesItFinishedForItsOwnCaller() throws {
        makeWindow()
        let caller = try XCTUnwrap(spawned.first)
        report(.idle, from: caller)
        let parent = try runHelper(named: "lead", from: caller)
        report(.idle, from: parent)
        let helper = try runHelper(from: parent)
        report(.working, from: helper)
        report(.done, from: helper)
        XCTAssertEqual(parent.inputs.last, .submit)

        let all = try waitOnChildren(of: caller, .all)

        let got = try XCTUnwrap(try all.reply?.get() as? WaitResult, "an idle parent handed a note counted as working")
        XCTAssertEqual(got.reason, .stopped)
    }
}
