import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlPaneRunTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var raised: [WindowController] = []
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

    private func makeWindow(firstTaskWindow: TimeInterval = 5) -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory, firstTaskWindow: firstTaskWindow)
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        var responder = ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first })
        responder.bringForward = { [unowned self] in raised.append($0) }
        return responder
    }

    private func send(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int? = nil)
        -> () -> ControlReply?
    {
        var reply: ControlReply?
        responder.respond(
            to: ControlRequest(id: 1, cmd: cmd, args: args, caller: pane.map(ControlCaller.init(pane:)))
        ) { reply = $0 }
        return { reply }
    }

    private func answer(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int? = nil) throws
        -> ControlReply
    {
        try XCTUnwrap(send(cmd, args, from: pane)(), "\(cmd.rawValue) did not answer at once")
    }

    private func run(_ args: ControlArgs, from pane: Int?) throws -> PaneRunResult {
        try XCTUnwrap(try answer(.paneRun, args, from: pane).get() as? PaneRunResult)
    }

    private func error(_ reply: ControlReply) -> ControlError? {
        guard case .failure(let error) = reply else { return nil }
        return error
    }

    private func token(of surface: RecordingSurface) throws -> Int {
        try XCTUnwrap(surface.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
    }

    private func surface(_ token: Int) throws -> RecordingSurface {
        try XCTUnwrap(spawned.first { (try? self.token(of: $0)) == token })
    }

    private func everyPane(_ c: WindowController) -> [ListResult.Pane] {
        c.listing().workspaces.flatMap(\.tabs).flatMap(\.panes)
    }

    private func listed(_ token: Int, in c: WindowController) throws -> ListResult.Pane {
        try XCTUnwrap(everyPane(c).first { $0.token == token })
    }

    private func script(of surface: RecordingSurface) -> String { surface.lastConfig?.args.last ?? "" }

    private func report(_ state: TerminalProgramStatus.State, from surface: RecordingSurface) {
        surface.delegate?.surface(surface, programStatusDidChange: TerminalProgramStatus(state: state, app: "claude"))
    }

    func test_runOpensABackgroundTabInTheCallersWorkspace_recordingItsNameAndParent() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let showing = c.activeTabIDForTesting

        let opened = try run(ControlArgs(cmd: "claude", name: "review"), from: caller)

        XCTAssertNil(opened.firstTask)
        XCTAssertEqual(c.activeTabIDForTesting, showing, "the helper took the screen")
        XCTAssertTrue(raised.isEmpty)
        XCTAssertEqual(c.listing().workspaces.flatMap(\.tabs).count, 2)
        let helper = try listed(opened.pane, in: c)
        XCTAssertEqual(helper.name, "review")
        XCTAssertEqual(helper.parent, caller)
        XCTAssertNil(helper.firstTask)
        XCTAssertNil(try listed(caller, in: c).name)
        let launched = script(of: try surface(opened.pane))
        XCTAssertTrue(launched.contains("claude; "), launched)
        XCTAssertFalse(launched.contains("exec "), "a launched pane started a shell after its program")
    }

    func test_splitPutsTheHelperBesideThePane_andFocusShowsIt() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))

        let opened = try run(ControlArgs(cmd: "htop", focus: true, split: .down), from: caller)

        let tabs = c.listing().workspaces.flatMap(\.tabs)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.panes.map(\.token), [caller, opened.pane])
        XCTAssertTrue(c.focusedSurfaceForTesting === (try surface(opened.pane)))
        XCTAssertEqual(try listed(opened.pane, in: c).parent, caller)
    }

    func test_focusShowsTheHelpersTab() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))

        let opened = try run(ControlArgs(cmd: "htop", focus: true), from: caller)

        XCTAssertTrue(c.focusedSurfaceForTesting === (try surface(opened.pane)))
    }

    func test_withoutACallerTheHelperHasNoParent() throws {
        let c = makeWindow()

        let opened = try run(ControlArgs(cmd: "htop", name: "top"), from: nil)

        XCTAssertNil(try listed(opened.pane, in: c).parent)
        XCTAssertEqual(try listed(opened.pane, in: c).name, "top")
    }

    func test_aNameIsUniqueAmongOpenPanes_andFreesWhenItsPaneCloses() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let first = try run(ControlArgs(cmd: "htop", name: "review", split: .right), from: caller)

        let duplicate = try answer(.paneRun, ControlArgs(cmd: "htop", name: "review"), from: caller)
        XCTAssertEqual(error(duplicate)?.code, .refused)
        XCTAssertEqual(everyPane(c).count, 2, "a refused run opened a pane")

        XCTAssertEqual(
            error(try answer(.paneRun, ControlArgs(cmd: "htop", name: "42"), from: caller))?.code, .badRequest)

        _ = try answer(.paneClose, ControlArgs(force: true, pane: .name("review")))
        XCTAssertNil(everyPane(c).first { $0.token == first.pane })
        let again = try run(ControlArgs(cmd: "htop", name: "review"), from: caller)
        XCTAssertEqual(try listed(again.pane, in: c).name, "review")
    }

    func test_aNameAddressesThePaneAnywhereATokenDoes() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let opened = try run(ControlArgs(cmd: "htop", name: "review"), from: caller)
        let helper = try surface(opened.pane)

        _ = try answer(.paneSend, ControlArgs(pane: .name("review"), text: "hi", enter: true))
        XCTAssertEqual(helper.inputs, [.paste("hi"), .submit])

        _ = try answer(.paneFocus, ControlArgs(pane: .name("review")))
        XCTAssertTrue(c.focusedSurfaceForTesting === helper)

        let split = try run(ControlArgs(cmd: "htop", pane: .name("review"), split: .right), from: caller)
        let tab = try XCTUnwrap(
            c.listing().workspaces.flatMap(\.tabs).first { $0.panes.contains { $0.token == opened.pane } })
        XCTAssertEqual(tab.panes.map(\.token), [opened.pane, split.pane])

        XCTAssertEqual(error(try answer(.paneRead, ControlArgs(pane: .name("nobody"))))?.code, .notFound)
    }

    func test_aChildStaysOpenWhenItsParentCloses() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let parent = try run(ControlArgs(cmd: "htop", split: .right), from: lead)
        let child = try run(ControlArgs(cmd: "htop", name: "child"), from: parent.pane)

        _ = try answer(.paneClose, ControlArgs(force: true, pane: .token(parent.pane)))

        XCTAssertNil(everyPane(c).first { $0.token == parent.pane })
        XCTAssertEqual(try listed(child.pane, in: c).parent, parent.pane)
    }

    func test_theTaskIsSentOnTheFirstReadyReport_andThePaneKeepsTheResult() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let reply = send(.paneRun, ControlArgs(cmd: "claude", name: "review", task: "Review x.swift"), from: caller)
        XCTAssertNil(reply(), "answered before the task was sent")
        let helper = try XCTUnwrap(spawned.last)
        XCTAssertTrue(helper.inputs.isEmpty)

        report(.idle, from: helper)
        waitUntil(reply() != nil, "the run's answer")

        let result = try XCTUnwrap(try XCTUnwrap(reply()).get() as? PaneRunResult)
        XCTAssertEqual(result.firstTask, .delivered)
        XCTAssertEqual(helper.inputs, [.paste("Review x.swift"), .submit])
        XCTAssertEqual(try listed(result.pane, in: c).firstTask, .delivered)

        report(.idle, from: helper)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(helper.inputs.count, 2, "a later report sent the task again")
    }

    func test_aBlockedOrBusyFirstReportHoldsTheTaskAndSaysWhy() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        for (state, reason) in [
            (TerminalProgramStatus.State.blocked(.permission), FirstTask.Reason.blocked),
            (.working, .notReady), (.failed, .notReady),
        ] {
            let reply = send(.paneRun, ControlArgs(cmd: "claude", task: "go"), from: caller)
            let helper = try XCTUnwrap(spawned.last)

            report(state, from: helper)
            waitUntil(reply() != nil, "the run's answer")

            let result = try XCTUnwrap(try XCTUnwrap(reply()).get() as? PaneRunResult)
            XCTAssertEqual(result.firstTask, .held(reason), "\(state)")
            XCTAssertTrue(helper.inputs.isEmpty, "\(state) was sent the task")
            XCTAssertEqual(try listed(result.pane, in: c).firstTask, .held(reason))
        }
    }

    func test_aProgramThatNeverReportsGetsNoStatus() throws {
        let c = makeWindow(firstTaskWindow: 0.1)
        let caller = try token(of: XCTUnwrap(spawned.first))

        let reply = send(.paneRun, ControlArgs(cmd: "htop", task: "go"), from: caller)
        waitUntil(reply() != nil, "the run's answer")

        let result = try XCTUnwrap(try XCTUnwrap(reply()).get() as? PaneRunResult)
        XCTAssertEqual(result.firstTask, .held(.noStatus))
        XCTAssertEqual(try listed(result.pane, in: c).firstTask, .held(.noStatus))
        XCTAssertTrue(try surface(result.pane).inputs.isEmpty)
    }

    func test_aProgramThatExitsBeforeReportingIsNotReady() throws {
        _ = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let reply = send(.paneRun, ControlArgs(cmd: "claude", task: "go", split: .right), from: caller)
        let helper = try XCTUnwrap(spawned.last)

        helper.delegate?.surfaceDidExit(helper, code: 1)
        waitUntil(reply() != nil, "the run's answer")

        let result = try XCTUnwrap(try XCTUnwrap(reply()).get() as? PaneRunResult)
        XCTAssertEqual(result.firstTask, .held(.notReady))
    }

    func test_aLaunchedPaneClosesWhenItsProgramExits_keepingItsExitForLater() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let opened = try run(ControlArgs(cmd: "npm test", name: "tests", split: .right), from: caller)
        let helper = try surface(opened.pane)
        helper.scrollback = ["FAIL x.test.ts"]

        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 1))
        helper.delegate?.surfaceDidExit(helper, code: 0)

        XCTAssertEqual(everyPane(c).map(\.token), [caller])
        let exit = try XCTUnwrap(c.launchedPaneExits.exit(of: opened.pane))
        XCTAssertEqual(exit.exitCode, 3)
        XCTAssertEqual(exit.record.name, "tests")
        XCTAssertEqual(exit.record.parent, caller)
        XCTAssertTrue(exit.lastLines?.hasPrefix("FAIL x.test.ts") == true, "\(String(describing: exit.lastLines))")
    }

    func test_aLaunchedTabClosesWithItsProgram() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let opened = try run(ControlArgs(cmd: "npm test"), from: caller)
        let helper = try surface(opened.pane)

        helper.delegate?.surfaceDidExit(helper, code: 0)

        XCTAssertEqual(c.listing().workspaces.flatMap(\.tabs).count, 1)
        XCTAssertNotNil(c.launchedPaneExits.exit(of: opened.pane))
    }

    func test_keepDropsToAShellInstead_andRecordsNoExit() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let opened = try run(ControlArgs(cmd: "npm test", split: .right, keep: true), from: caller)
        let helper = try surface(opened.pane)

        XCTAssertTrue(script(of: helper).contains("exec "), script(of: helper))
        helper.delegate?.surfaceDidExit(helper, code: 0)
        XCTAssertNil(c.launchedPaneExits.exit(of: opened.pane))
    }
}
