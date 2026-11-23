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
        c.appWindows = { [weak self] in self?.controllers ?? [] }
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
        XCTAssertTrue(launched.contains("( claude\n); "), launched)
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

    func test_runWaitWithATaskWhoseProgramExitsBeforeReportingAnswersExited() throws {
        _ = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let reply = send(.paneRun, ControlArgs(cmd: "./tool", task: "go", split: .right, wait: true), from: caller)
        let helper = try XCTUnwrap(spawned.last)
        helper.scrollback = ["boom"]

        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 1, duration: 1))
        helper.delegate?.surfaceDidExit(helper, code: 0)
        waitUntil(reply() != nil, "the run's answer")

        let got = try XCTUnwrap(try XCTUnwrap(reply()).get() as? WaitResult)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 1)
        XCTAssertTrue(got.text?.hasPrefix("boom") == true, "\(String(describing: got.text))")
        XCTAssertEqual(got.pane?.firstTask, .held(.notReady))
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

    func test_aLaunchedPaneWhoseExitMarkTrailsItsExitStaysOpenForTheMark_andKeepsItsCode() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let opened = try run(ControlArgs(cmd: "npm test", split: .right), from: caller)
        let helper = try surface(opened.pane)

        helper.delegate?.surfaceDidExit(helper, code: 0)
        XCTAssertEqual(everyPane(c).map(\.token), [caller, opened.pane], "closed before its exit mark could land")
        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 1))

        XCTAssertEqual(everyPane(c).map(\.token), [caller])
        XCTAssertEqual(c.launchedPaneExits.exit(of: opened.pane)?.exitCode, 3)
    }

    func test_aLaunchedPaneWhoseExitMarkNeverLandsClosesAfterTheGrace_withNoCode() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let opened = try run(ControlArgs(cmd: "npm test", split: .right), from: caller)
        let helper = try surface(opened.pane)

        helper.delegate?.surfaceDidExit(helper, code: 0)

        waitUntil(everyPane(c).count == 1, "the pane to close", timeout: 2)
        let exit = try XCTUnwrap(c.launchedPaneExits.exit(of: opened.pane))
        XCTAssertNil(exit.exitCode)
    }

    func test_aLaunchedTabClosesWithItsProgram() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let opened = try run(ControlArgs(cmd: "npm test"), from: caller)
        let helper = try surface(opened.pane)

        helper.delegate?.surface(helper, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
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

    private func isOpen(_ token: Int, in c: WindowController) -> Bool { everyPane(c).contains { $0.token == token } }

    private func family(in c: WindowController, outliving: Bool = false) throws
        -> (lead: Int, parent: Int, child: Int, grandchild: Int)
    {
        let lead = try token(of: XCTUnwrap(spawned.first))
        let parent = try run(ControlArgs(cmd: "claude", focus: true, split: .right), from: lead).pane
        let child = try run(
            ControlArgs(cmd: "claude", name: "review", outliveParent: outliving ? true : nil), from: parent
        ).pane
        let grandchild = try run(ControlArgs(cmd: "claude", name: "tests"), from: child).pane
        return (lead, parent, child, grandchild)
    }

    private func pressClose(_ c: WindowController) throws {
        let content = try XCTUnwrap(c.window.contentView)
        let button = try XCTUnwrap(
            Self.descendants(of: content).compactMap { $0 as? AppButton }.first { $0.title == "Close" })
        button.performClick(nil)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    func test_closingAPaneClosesItsChildrenAndTheirsWhereverTheyAre() throws {
        let c = makeWindow()
        let family = try family(in: c)
        XCTAssertEqual(c.listing().workspaces.flatMap(\.tabs).count, 3)

        _ = try answer(.paneClose, ControlArgs(pane: .token(family.parent)))

        waitUntil(!isOpen(family.grandchild, in: c), "the grandchild closing")
        XCTAssertFalse(isOpen(family.child, in: c))
        XCTAssertTrue(isOpen(family.lead, in: c))
        XCTAssertEqual(c.listing().workspaces.flatMap(\.tabs).count, 1)
    }

    func test_aPaneWithARunningChildIsRefusedNamingIt_andForceClosesBoth() throws {
        let c = makeWindow()
        let family = try family(in: c)
        try surface(family.grandchild).isBusy = true
        try surface(family.grandchild).title = "swift test --parallel"

        let refusal = try XCTUnwrap(error(try answer(.paneClose, ControlArgs(pane: .token(family.parent)))))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.message, "Closing pane \(family.parent) would stop tests.")
        XCTAssertEqual(refusal.details?.panes.map(\.token), [family.grandchild])
        XCTAssertEqual(refusal.details?.panes.map(\.name), ["tests"])
        XCTAssertTrue(isOpen(family.parent, in: c))

        _ = try answer(.paneClose, ControlArgs(force: true, pane: .token(family.parent)))
        waitUntil(!isOpen(family.grandchild, in: c), "the grandchild closing")
    }

    func test_aParentClosesItsRunningHelperAndThatHelpersChildrenWithoutForce() throws {
        let c = makeWindow()
        let family = try family(in: c)
        try surface(family.child).isBusy = true
        try surface(family.grandchild).isBusy = true

        let refused = try XCTUnwrap(
            error(try answer(.paneClose, ControlArgs(pane: .token(family.child)), from: family.lead)),
            "a pane that is not the helper's parent closes its running work")
        XCTAssertEqual(refused.details?.panes.map(\.token), [family.child, family.grandchild])
        XCTAssertTrue(isOpen(family.child, in: c))

        XCTAssertTrue(try answer(.paneClose, ControlArgs(pane: .token(family.child)), from: family.parent).isSuccess)
        waitUntil(!isOpen(family.grandchild, in: c), "the helper's child closing with it")
        XCTAssertFalse(isOpen(family.child, in: c))
        XCTAssertTrue(isOpen(family.parent, in: c))
    }

    func test_aParentClosesARunningHelperSplitBesideIt() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let helper = try run(ControlArgs(cmd: "claude", split: .right), from: lead).pane
        try surface(helper).isBusy = true

        XCTAssertTrue(try answer(.paneClose, ControlArgs(pane: .token(helper)), from: lead).isSuccess)
        XCTAssertFalse(isOpen(helper, in: c))
    }

    func test_aParentClosingItsHelperIsStillRefusedOverRunningWorkItDidNotStart() throws {
        let c = makeWindow()
        let family = try family(in: c)
        try surface(family.child).isBusy = true
        let childTab = try XCTUnwrap(c.pane(token: family.child)?.tab)
        try XCTUnwrap(c.controllerForTesting(tab: childTab)).toggleBottomDrawer()
        let drawer = try XCTUnwrap(spawned.last)
        drawer.isBusy = true

        let refusal = try XCTUnwrap(
            error(try answer(.paneClose, ControlArgs(pane: .token(family.child)), from: family.parent)))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.panes.map(\.token), [try token(of: drawer)])
        XCTAssertTrue(isOpen(family.child, in: c))
    }

    func test_theCloseWarningNamesARunningChild_andConfirmingClosesIt() throws {
        let c = makeWindow()
        let family = try family(in: c)
        try surface(family.child).isBusy = true
        try surface(family.child).title = "Reviewing x.swift"
        XCTAssertTrue(c.focusedSurfaceForTesting === (try surface(family.parent)))

        c.handle(.closePane)

        XCTAssertTrue(c.isConfirmOpen, "a running child closes without asking")
        XCTAssertTrue(
            toastTexts(in: c).contains("Closing this pane will stop the process running in it, including review."),
            "\(toastTexts(in: c))")
        XCTAssertTrue(isOpen(family.child, in: c))

        try pressClose(c)
        waitUntil(!isOpen(family.grandchild, in: c), "the grandchild closing")
        XCTAssertFalse(isOpen(family.parent, in: c))
        XCTAssertFalse(isOpen(family.child, in: c))
    }

    func test_closingATabOrAWorkspaceClosesTheChildrenStartedInIt() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let helper = try run(ControlArgs(cmd: "claude"), from: lead).pane
        let child = try run(ControlArgs(cmd: "claude"), from: helper).pane
        let helperTab = try XCTUnwrap(c.pane(token: helper)?.tab)

        _ = try answer(.tabClose, ControlArgs(tab: ControlAddress.tab(window: c.windowID, tab: helperTab.raw)))
        waitUntil(!isOpen(child, in: c), "the child closing with its parent's tab")

        let other = c.openUnconfiguredWorkspace(at: FileManager.default.temporaryDirectory, named: "other")
        let otherPane = try XCTUnwrap(c.listing(of: other)?.tabs.first?.panes.first?.token)
        let placedHere = try run(ControlArgs(cmd: "claude", pane: .token(lead)), from: otherPane).pane
        XCTAssertEqual(
            c.pane(token: placedHere).flatMap { c.workspaceID(of: $0.tab) },
            c.pane(token: lead).flatMap { c.workspaceID(of: $0.tab) })

        _ = try answer(.workspaceClose, ControlArgs(workspace: "other"))
        waitUntil(!isOpen(placedHere, in: c), "a child in another workspace closing with its parent's")
        XCTAssertTrue(isOpen(lead, in: c))
    }

    private func childInAnotherWindow() throws -> (a: WindowController, b: WindowController, parent: Int, child: Int) {
        let a = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let b = makeWindow()
        let elsewhere = try token(of: XCTUnwrap(spawned.last))
        let parent = try run(ControlArgs(cmd: "claude", split: .right), from: lead).pane
        let child = try run(ControlArgs(cmd: "claude", pane: .token(elsewhere), name: "review"), from: parent).pane
        XCTAssertTrue(isOpen(child, in: b), "the child opened beside the pane it was given")
        return (a, b, parent, child)
    }

    func test_closingAParentClosesItsChildInAnotherWindow() throws {
        let family = try childInAnotherWindow()

        XCTAssertTrue(try answer(.paneClose, ControlArgs(pane: .token(family.parent))).isSuccess)

        waitUntil(!isOpen(family.child, in: family.b), "the child in the other window closing")
    }

    func test_closingAParentIsRefusedOverARunningChildInAnotherWindow() throws {
        let family = try childInAnotherWindow()
        try surface(family.child).isBusy = true

        let refusal = try XCTUnwrap(error(try answer(.paneClose, ControlArgs(pane: .token(family.parent)))))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.panes.map(\.token), [family.child])
        XCTAssertEqual(refusal.details?.panes.map(\.name), ["review"])
    }

    func test_closingAWindowAsksFirstOverARunningChildInAnotherWindow() throws {
        let family = try childInAnotherWindow()
        XCTAssertTrue(family.a.windowShouldClose(family.a.window))
        try surface(family.child).isBusy = true

        XCTAssertFalse(family.a.windowShouldClose(family.a.window))
    }

    func test_closingAWindowClosesTheChildrenItsPanesStartedInAnotherWindow() throws {
        let family = try childInAnotherWindow()

        family.a.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        waitUntil(!isOpen(family.child, in: family.b), "the child in the other window closing")
    }

    private func childThatIsAnotherWindowsLastTab() throws -> (a: WindowController, b: WindowController, parent: Int) {
        var config = GeneralConfig.builtIn
        config.floats = [
            ToolFloat(
                id: "btop", order: 0, title: "btop", icon: ToolFloatParser.defaultIcon, command: "btop", dir: nil,
                widthFraction: 0.8, heightFraction: 0.8, requiresGitRepo: false, persist: .window,
                toggle: Chord(command: true, shift: true, key: "b"))
        ]
        GeneralConfig.setCurrentForTesting(config)
        let family = try childInAnotherWindow()
        let elsewhere = try XCTUnwrap(everyPane(family.b).first { $0.token != family.child }?.token)
        let tab = try XCTUnwrap(family.b.pane(token: elsewhere)?.tab)
        XCTAssertTrue(
            try answer(.tabClose, ControlArgs(tab: ControlAddress.tab(window: family.b.windowID, tab: tab.raw)))
                .isSuccess)
        XCTAssertEqual(everyPane(family.b).map(\.token), [family.child])
        return (family.a, family.b, family.parent)
    }

    func test_aChildThatIsAnotherWindowsLastTabCountsThatWindowClosing_andItsRunningFloats() throws {
        let family = try childThatIsAnotherWindowsLastTab()
        let before = spawned.count
        family.b.handle(.toggleToolFloat("btop"))
        try XCTUnwrap(spawned.dropFirst(before).first, "opening btop spawns its program").isBusy = true

        let refusal = try XCTUnwrap(error(try answer(.paneClose, ControlArgs(pane: .token(family.parent)))))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.closesWindow, true)
        XCTAssertEqual(refusal.details?.floats, ["btop"])
        XCTAssertTrue(refusal.message.contains("close another window"), refusal.message)
    }

    func test_closingAWindowAsksFirstWhenAChildIsAnotherWindowsLastTab() throws {
        let family = try childThatIsAnotherWindowsLastTab()

        XCTAssertFalse(family.a.windowShouldClose(family.a.window))
        let content = try XCTUnwrap(family.a.window.contentView)
        let texts = Self.descendants(of: content).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(
            texts.contains { $0.hasSuffix("It also closes another window.") }, "the confirmation says so: \(texts)")
    }

    func test_removingAWorktreeCountsARunningChildInAnotherWindowOnce() throws {
        let a = makeWindow()
        _ = makeWindow()
        let elsewhere = try token(of: XCTUnwrap(spawned.last))
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-run-\(UUID().uuidString)", isDirectory: true)
        let opened = try XCTUnwrap(try answer(.tabNew, ControlArgs(cwd: worktree.path)).get() as? TabResult)
        XCTAssertNotNil(a.pane(token: opened.pane), "the worktree tab opened in the first window")
        let child = try run(ControlArgs(cmd: "claude", pane: .token(elsewhere), name: "tests"), from: opened.pane).pane
        try surface(child).isBusy = true

        let stakes = controllers.map { $0.closeStakes(atPath: worktree) }
        let closes = controllers.reduce(ClosedByRemoval()) {
            $0.adding($1.closedByRemoval(atPath: worktree), isThisWindow: $1 === a)
        }

        XCTAssertEqual(stakes.flatMap(\.panes).map(\.token), [child])
        XCTAssertEqual(closes.stopping, ["tests"])
    }

    func test_removingAWorktreeOpenInTwoWindowsCountsAChildInBothOnlyOnce() throws {
        let a = makeWindow()
        let b = makeWindow()
        let elsewhere = try token(of: XCTUnwrap(spawned.last))
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-run-\(UUID().uuidString)", isDirectory: true)
        let here = try XCTUnwrap(try answer(.tabNew, ControlArgs(cwd: worktree.path)).get() as? TabResult)
        let there = try XCTUnwrap(
            try answer(.tabNew, ControlArgs(cwd: worktree.path), from: elsewhere).get() as? TabResult)
        XCTAssertNotNil(b.pane(token: there.pane), "the second worktree tab opened in the second window")
        let child = try run(
            ControlArgs(cmd: "claude", pane: .token(there.pane), name: "tests", split: .right), from: here.pane
        ).pane
        try surface(child).isBusy = true

        let stakes = controllers.map { $0.closeStakes(atPath: worktree) }
        let closes = controllers.reduce(ClosedByRemoval()) {
            $0.adding($1.closedByRemoval(atPath: worktree), isThisWindow: $1 === a)
        }

        XCTAssertEqual(stakes.flatMap(\.panes).map(\.token), [child])
        XCTAssertEqual(closes.stopping, [])
    }

    func test_aLaunchedPaneExitingClosesItsChildren() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let helper = try run(ControlArgs(cmd: "npm test", split: .right), from: lead).pane
        let child = try run(ControlArgs(cmd: "claude"), from: helper).pane
        let exiting = try surface(helper)

        exiting.delegate?.surfaceDidExit(exiting, code: 0)

        waitUntil(!isOpen(child, in: c), "the child closing with its parent's exit")
    }

    func test_anOutlivingChildStaysOpenWithNoParent_andKeepsItsOwnChildren() throws {
        let c = makeWindow()
        let family = try family(in: c, outliving: true)

        _ = try answer(.paneClose, ControlArgs(pane: .token(family.parent)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(isOpen(family.child, in: c))
        XCTAssertTrue(isOpen(family.grandchild, in: c))
        XCTAssertNil(try listed(family.child, in: c).parent, "it claims a parent that closed")
        XCTAssertEqual(try listed(family.grandchild, in: c).parent, family.child)
    }

    func test_anAgentQuittingInAPaneThatStaysOpenClosesNothing() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let helper = try run(ControlArgs(cmd: "claude", split: .right, keep: true), from: lead).pane
        let child = try run(ControlArgs(cmd: "claude"), from: helper).pane
        let quitting = try surface(helper)

        quitting.delegate?.surface(quitting, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(isOpen(helper, in: c))
        XCTAssertTrue(isOpen(child, in: c))
        XCTAssertEqual(try listed(child, in: c).parent, helper)
    }

    func test_aChildThatIsItsTabsLastPaneCountsThatTabsRunningDrawer() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let parent = try run(ControlArgs(cmd: "claude", focus: true, split: .right), from: lead).pane
        let child = try run(ControlArgs(cmd: "claude", name: "review"), from: parent).pane
        let childTab = try XCTUnwrap(c.pane(token: child)?.tab)
        try XCTUnwrap(c.controllerForTesting(tab: childTab)).toggleBottomDrawer()
        let drawer = try XCTUnwrap(spawned.last)
        drawer.isBusy = true

        let refusal = try XCTUnwrap(error(try answer(.paneClose, ControlArgs(pane: .token(parent)))))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.panes.map(\.token), [try token(of: drawer)])
        c.handle(.closePane)
        XCTAssertTrue(
            toastTexts(in: c).contains(
                "Closing this pane will stop the process running in it, including the bottom drawer."),
            "\(toastTexts(in: c))")
    }

    func test_removingAWorktreeCountsARunningChildItStartedElsewhere() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-run-\(UUID().uuidString)", isDirectory: true)
        let opened = try XCTUnwrap(
            try answer(.tabNew, ControlArgs(cwd: worktree.path)).get() as? TabResult)
        let child = try run(ControlArgs(cmd: "claude", pane: .token(lead), name: "review"), from: opened.pane).pane
        try surface(child).isBusy = true

        let stakes = c.closeStakes(atPath: worktree)

        XCTAssertTrue(stakes.isRunning)
        XCTAssertEqual(stakes.panes.map(\.token), [child])
    }

    func test_theWorktreeRemovalCardNamesARunningChildItStartedElsewhere() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-run-\(UUID().uuidString)", isDirectory: true)
        let opened = try XCTUnwrap(try answer(.tabNew, ControlArgs(cwd: worktree.path)).get() as? TabResult)
        let child = try run(ControlArgs(cmd: "claude", pane: .token(lead), name: "review"), from: opened.pane).pane
        try surface(child).isBusy = true
        try surface(child).title = "Reviewing x.swift"

        let closes = c.closedByRemoval(atPath: worktree)
        let card = WorktreeRemovalMessage.items(
            for: Worktree(path: worktree, branch: "feat", head: "0123456789abcdef", isLocked: false),
            state: WorktreeState(files: [], lostCommits: 0), carried: [], closes: closes)

        XCTAssertEqual(closes.stopping, ["review"])
        XCTAssertTrue(
            card.contains { $0.mark == .warning && $0.text.map(\.text).joined() == "Stops review in other tabs" },
            "\(card.map { $0.text.map(\.text).joined() })")
    }

    func test_aChildThatIsItsTabsLastPaneCountsThatTabsRunningFloat() throws {
        let c = makeWindow()
        c.floatsForTesting.resolveRepoRoot = { $1($0) }
        let lead = try token(of: XCTUnwrap(spawned.first))
        let parent = try run(ControlArgs(cmd: "claude", split: .right), from: lead).pane
        let child = try run(ControlArgs(cmd: "claude"), from: parent).pane
        let leadTab = try XCTUnwrap(c.pane(token: lead)?.tab)
        c.selectTab(try XCTUnwrap(c.pane(token: child)?.tab))
        let before = spawned.count
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        try XCTUnwrap(spawned.dropFirst(before).first, "opening Scratch spawns a shell").isBusy = true
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        c.selectTab(leadTab)

        let refusal = try XCTUnwrap(error(try answer(.paneClose, ControlArgs(pane: .token(parent)))))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.floats, [ToolFloat.scratch.title])
    }

    func test_runWaitWithOutputAnswersOnTextThePaneShowsBeforeAnyLaterWaitCouldBegin() throws {
        makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let reply = send(
            .paneRun, ControlArgs(cmd: "npm run dev", name: "dev", output: "ready on", wait: true), from: caller)
        let server = try XCTUnwrap(spawned.last)
        server.rows = ["> dev", "compiling"]
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(reply())

        server.rows = ["> dev", "compiling", "ready on http://localhost:3000"]

        waitUntil(reply() != nil, "the run to answer")
        let got = try XCTUnwrap(try XCTUnwrap(reply()).get() as? WaitResult)
        XCTAssertEqual(got.reason, .output)
        XCTAssertEqual(got.pane?.name, "dev")
    }

    func test_runOutputNeedsWaitAndOneLine() throws {
        makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))

        for args in [
            ControlArgs(cmd: "npm run dev", output: "ready"),
            ControlArgs(cmd: "npm run dev", output: "a\nb", wait: true),
        ] {
            XCTAssertEqual(error(try answer(.paneRun, args, from: caller))?.code, .badRequest)
        }
        XCTAssertEqual(spawned.count, 1, "a refused run opened a pane")
    }

    func test_getAndWaitReachAPaneByItsName_andGetCarriesWhatRunRecorded() throws {
        _ = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let helper = try run(ControlArgs(cmd: "claude", name: "review"), from: lead).pane

        let got = try XCTUnwrap(try answer(.paneGet, ControlArgs(pane: .name("review"))).get() as? ListResult.Pane)
        XCTAssertEqual(got.token, helper)
        XCTAssertEqual(got.name, "review")
        XCTAssertEqual(got.parent, lead)

        let waiter = responder
        var reply: ControlReply?
        waiter.respond(
            to: ControlRequest(id: 2, cmd: .paneWait, args: ControlArgs(pane: .name("review"), timeout: 1)),
            hangup: ControlHangup()
        ) { reply = $0 }
        waitUntil(reply != nil, "the wait to answer", timeout: 3)
        let waited = try XCTUnwrap(try XCTUnwrap(reply).get() as? WaitResult)
        XCTAssertEqual(waited.reason, .timeout)
        XCTAssertEqual(waited.pane?.token, helper)
        XCTAssertEqual(waited.pane?.name, "review")
    }
}
