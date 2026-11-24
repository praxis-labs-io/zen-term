import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class FloatPaneTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
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
        GeneralConfig.setCurrentForTesting(.builtInWithStickyCards)
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

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.appWindows = { [weak self] in self?.controllers ?? [] }
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        ControlResponder(windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first })
    }

    private func answer(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int? = nil) throws
        -> ControlReply
    {
        var reply: ControlReply?
        responder.respond(
            to: ControlRequest(id: 1, cmd: cmd, args: args, caller: pane.map(ControlCaller.init(pane:)))
        ) { reply = $0 }
        return try XCTUnwrap(reply, "\(cmd.rawValue) did not answer at once")
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

    private func isOpen(_ token: Int, in c: WindowController) -> Bool { everyPane(c).contains { $0.token == token } }

    private func tab(of token: Int, in c: WindowController) throws -> TabController {
        let tab = try XCTUnwrap(c.pane(token: token)?.tab)
        return try XCTUnwrap(c.controllerForTesting(tab: tab))
    }

    private func openFloat(
        in c: WindowController, beside token: Int, running program: PaneProgram? = nil, parent: Int? = nil
    ) throws -> Int {
        let owner = try tab(of: token, in: c)
        let id = try XCTUnwrap(c.pane(token: token)?.tab)
        let float = try XCTUnwrap(c.openFloatPane(in: id, running: program, cwd: nil))
        if let parent { owner.updateRecord(pane: float) { $0.parent = parent } }
        return float
    }

    private func show(_ token: Int, in c: WindowController) throws {
        let found = try XCTUnwrap(c.pane(token: token))
        c.focus(found.pane.surfaceID, in: found.tab)
    }

    private func error(_ reply: ControlReply) -> ControlError? {
        guard case .failure(let error) = reply else { return nil }
        return error
    }

    private func becomeAgent(_ token: Int) throws {
        let program = try surface(token)
        program.delegate?.surface(
            program, programStatusDidChange: TerminalProgramStatus(state: .working, app: "claude"))
        drainMainQueue()
    }

    private func run(_ args: ControlArgs, from caller: Int?) throws -> Int {
        try XCTUnwrap(try answer(.paneRun, args, from: caller).get() as? PaneRunResult).pane
    }

    private func tabCount(_ c: WindowController) -> Int { c.listing().workspaces.flatMap(\.tabs).count }

    private func isFloat(_ token: Int, in c: WindowController) -> Bool {
        everyPane(c).first { $0.token == token }?.float == true
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    func test_aFloatPaneHasItsOwnTokenAndControlSocket_andListsAsAFloat() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))

        let float = try openFloat(in: c, beside: lead)

        let launched = try surface(float).lastConfig?.environment
        XCTAssertEqual(launched?[ControlEndpoint.environmentKey], ControlServer.socketPath)
        XCTAssertNotEqual(float, lead)
        let listed = try XCTUnwrap(everyPane(c).first { $0.token == float })
        XCTAssertEqual(listed.float, true)
        XCTAssertNil(listed.drawer)
        XCTAssertNil(try XCTUnwrap(everyPane(c).first { $0.token == lead }).float)
        XCTAssertEqual(c.listing().workspaces.flatMap(\.tabs).count, 1, "a float pane opened a tab")
    }

    func test_zenReachesAHiddenFloatPaneByItsToken() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)

        let got = try XCTUnwrap(try answer(.paneGet, ControlArgs(pane: .token(float))).get() as? ListResult.Pane)
        _ = try answer(.paneSend, ControlArgs(pane: .token(float), text: "ls"))

        XCTAssertEqual(got.token, float)
        XCTAssertEqual(try surface(float).pastes, ["ls"])
        XCTAssertNil(c.floatsForTesting.shownSurface, "reaching it showed it")
    }

    func test_closingAFloatPaneClosesOnlyIt_evenBesideItsTabsLastPane() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)

        XCTAssertNil(error(try answer(.paneClose, ControlArgs(pane: .token(float)))))

        XCTAssertFalse(isOpen(float, in: c))
        XCTAssertTrue(isOpen(lead, in: c), "closing the float closed its tab")
        XCTAssertTrue(try surface(float).terminated)
        XCTAssertFalse(NavRegistry.shared.isLive(token: float))
    }

    func test_aFloatPaneClosesWithItsTab() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let other = try XCTUnwrap(try answer(.tabNew).get() as? TabResult).pane
        let float = try openFloat(in: c, beside: other)

        XCTAssertNil(error(try answer(.paneClose, ControlArgs(pane: .token(other)))))

        XCTAssertFalse(isOpen(float, in: c))
        XCTAssertTrue(try surface(float).terminated)
        XCTAssertTrue(isOpen(lead, in: c))
    }

    func test_aFloatPaneClosesWithItsParentPane() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let parent = try XCTUnwrap(
            try answer(.paneSplit, ControlArgs(pane: .token(lead), dir: .right)).get() as? PaneResult
        ).pane
        let float = try openFloat(in: c, beside: lead, parent: parent)

        XCTAssertNil(error(try answer(.paneClose, ControlArgs(pane: .token(parent)))))

        waitUntil(!isOpen(float, in: c), "the float closing with its parent")
        XCTAssertTrue(isOpen(lead, in: c))
    }

    func test_closingItsParentIsRefusedOverARunningFloatPane_namingIt() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let parent = try XCTUnwrap(
            try answer(.paneSplit, ControlArgs(pane: .token(lead), dir: .right)).get() as? PaneResult
        ).pane
        let float = try openFloat(in: c, beside: lead, parent: parent)
        try surface(float).isBusy = true

        let refusal = try XCTUnwrap(error(try answer(.paneClose, ControlArgs(pane: .token(parent)))))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.panes.map(\.token), [float])
    }

    func test_aLaunchedFloatPaneClosesOnExit_andZenWaitReadsItsExit() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(
            in: c, beside: lead, running: PaneProgram(command: "npm test", exitClosesPane: true, marksExit: true),
            parent: lead)
        let program = try surface(float)
        program.scrollback = ["FAIL x.test.ts"]

        program.delegate?.surface(program, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 1))
        program.delegate?.surfaceDidExit(program, code: 0)

        XCTAssertFalse(isOpen(float, in: c))
        let got = try XCTUnwrap(
            try answer(.paneWait, ControlArgs(pane: .token(float))).get() as? WaitResult)
        XCTAssertEqual(got.reason, .exited)
        XCTAssertEqual(got.exitCode, 3)
        XCTAssertTrue(got.text?.hasPrefix("FAIL x.test.ts") == true, "\(String(describing: got.text))")
        XCTAssertEqual(got.pane?.parent, lead)
        XCTAssertEqual(got.pane?.float, true)
    }

    func test_aFloatPaneWhoseExitMarkTrailsItsExitWaitsForIt() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(
            in: c, beside: lead, running: PaneProgram(command: "npm test", exitClosesPane: true, marksExit: true))
        let program = try surface(float)

        program.delegate?.surfaceDidExit(program, code: 0)
        XCTAssertTrue(isOpen(float, in: c), "closed before its exit mark could land")
        program.delegate?.surface(program, commandDidFinish: TerminalCommandResult(exitCode: 3, duration: 1))

        XCTAssertFalse(isOpen(float, in: c))
        XCTAssertEqual(c.launchedPaneExits.exit(of: float)?.exitCode, 3)
    }

    func test_showingAFloatPaneUsesTheFloatSlot_andHidingItKeepsItRunning() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)

        try show(float, in: c)
        XCTAssertTrue(c.floatsForTesting.shownSurface === (try surface(float)))

        c.floatsForTesting.close()
        XCTAssertNil(c.floatsForTesting.shownSurface)
        XCTAssertFalse(try surface(float).terminated)
        XCTAssertTrue(isOpen(float, in: c))
    }

    func test_openingAnotherFloatHidesAFloatPane_andAConfigChangeLeavesItShown() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        try show(float, in: c)

        c.floatsForTesting.prune(against: ToolFloatCatalog.all)
        XCTAssertTrue(c.floatsForTesting.shownSurface === (try surface(float)), "a config change closed it")

        c.floatsForTesting.toggle(.scratch)
        XCTAssertFalse(c.floatsForTesting.shownSurface === (try surface(float)))
        XCTAssertFalse(try surface(float).terminated)
        XCTAssertTrue(isOpen(float, in: c))
    }

    func test_closingAShownFloatPaneTakesItsCardDown() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        try show(float, in: c)

        _ = try answer(.paneClose, ControlArgs(pane: .token(float)))

        XCTAssertFalse(c.floatsForTesting.isOpen)
    }

    func test_aHiddenFloatPaneIsSizedToTheCardItShowsIn() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        let hidden = try surface(float).view.frame.size
        XCTAssertGreaterThan(hidden.width, 0)

        try show(float, in: c)
        c.window.contentView?.layoutSubtreeIfNeeded()

        let shown = try surface(float).view.frame.size
        XCTAssertEqual(shown.width, hidden.width, accuracy: 1, "it reflows when first shown")
        XCTAssertEqual(shown.height, hidden.height, accuracy: 1, "it reflows when first shown")
    }

    func test_aHiddenFloatPaneAskingIsUnseen_untilItIsShown() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        let program = try surface(float)
        let id = try XCTUnwrap(c.pane(token: float)?.pane.surfaceID)

        program.delegate?.surface(
            program, didPostNotification: TerminalNotification(title: "Claude Code", body: "Claude needs you"))
        drainMainQueue()
        XCTAssertEqual(c.surfaceAttentionForTesting(id), .waiting, "its tab is on screen, but it is not")

        try show(float, in: c)
        drainMainQueue()
        XCTAssertEqual(c.surfaceAttentionForTesting(id), .idle)
    }

    func test_aShownFloatPaneAskingIsAlreadySeen() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        let program = try surface(float)
        let id = try XCTUnwrap(c.pane(token: float)?.pane.surfaceID)
        try show(float, in: c)

        program.delegate?.surface(
            program, didPostNotification: TerminalNotification(title: "Claude Code", body: "Claude needs you"))
        drainMainQueue()

        XCTAssertNotEqual(c.surfaceAttentionForTesting(id), .waiting)
    }

    func test_aFloatPaneDoesNotSplit() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)

        let refusal = try XCTUnwrap(error(try answer(.paneSplit, ControlArgs(pane: .token(float), dir: .right))))

        XCTAssertEqual(refusal.code, .badRequest)
    }

    func test_runFromAnAgentsPaneOpensAHiddenFloatInItsTab() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)
        let showing = c.activeTabIDForTesting

        let helper = try run(ControlArgs(cmd: "claude", name: "review"), from: lead)

        XCTAssertTrue(isFloat(helper, in: c))
        XCTAssertEqual(tabCount(c), 1)
        XCTAssertEqual(c.pane(token: helper)?.tab, c.pane(token: lead)?.tab)
        XCTAssertEqual(c.activeTabIDForTesting, showing)
        XCTAssertNil(c.floatsForTesting.shownSurface, "the float took the screen")
        XCTAssertEqual(everyPane(c).first { $0.token == helper }?.parent, lead)
        XCTAssertEqual(everyPane(c).first { $0.token == helper }?.name, "review")
    }

    func test_runFromAPlainShellOrNoPaneOpensABackgroundTab() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))

        let fromShell = try run(ControlArgs(cmd: "htop"), from: lead)
        let fromNowhere = try run(ControlArgs(cmd: "htop"), from: nil)

        XCTAssertFalse(isFloat(fromShell, in: c))
        XCTAssertFalse(isFloat(fromNowhere, in: c))
        XCTAssertEqual(tabCount(c), 3)
    }

    func test_anAgentsRunOpensATabWhenItOutlivesItsParent_orAsksForATab() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)

        let outliving = try run(ControlArgs(cmd: "claude", outliveParent: true), from: lead)
        let tab = try run(ControlArgs(cmd: "claude", float: false), from: lead)

        XCTAssertFalse(isFloat(outliving, in: c))
        XCTAssertFalse(isFloat(tab, in: c))
        XCTAssertEqual(tabCount(c), 3)
    }

    func test_floatFromAPaneAnAgentStartedOpensAFloat_butItsDefaultIsATab() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)
        let shell = try run(ControlArgs(cmd: "zsh", float: false), from: lead)

        let asked = try run(ControlArgs(cmd: "htop", float: true), from: shell)
        let defaulted = try run(ControlArgs(cmd: "htop"), from: shell)

        XCTAssertTrue(isFloat(asked, in: c))
        XCTAssertFalse(isFloat(defaulted, in: c))
    }

    func test_anAgentsRunIntoAnotherWindowOpensATab_andItsSameWindowRunStillFloats() throws {
        let home = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)
        let other = makeWindow()
        let target = try XCTUnwrap(everyPane(other).first?.token)
        let sibling = try run(ControlArgs(cmd: "zsh", float: false), from: lead)

        let across = try run(ControlArgs(cmd: "htop", pane: .token(target)), from: lead)
        let beside = try run(ControlArgs(cmd: "htop", pane: .token(sibling)), from: lead)

        XCTAssertFalse(isFloat(across, in: other))
        XCTAssertEqual(tabCount(other), 2)
        XCTAssertTrue(isFloat(beside, in: home))
    }

    func test_aFloatIntoAnotherWindowIsRefused() throws {
        _ = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)
        let other = makeWindow()
        let target = try XCTUnwrap(everyPane(other).first?.token)

        let refused = try XCTUnwrap(
            error(try answer(.paneRun, ControlArgs(cmd: "htop", pane: .token(target), float: true), from: lead)))

        XCTAssertEqual(refused.code, .refused)
        XCTAssertEqual(everyPane(other).count, 1)
    }

    func test_floatWithNoAgentAboveIsRefused() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))

        let fromShell = try XCTUnwrap(error(try answer(.paneRun, ControlArgs(cmd: "htop", float: true), from: lead)))
        let fromNowhere = try XCTUnwrap(error(try answer(.paneRun, ControlArgs(cmd: "htop", float: true))))

        XCTAssertEqual(fromShell.code, .refused)
        XCTAssertEqual(fromNowhere.code, .refused)
        XCTAssertEqual(everyPane(c).count, 1)
    }

    func test_aFloatOrTabWithASplit_andAFloatThatOutlivesItsParent_areRefused() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)

        for args in [
            ControlArgs(cmd: "htop", split: .right, float: true),
            ControlArgs(cmd: "htop", split: .right, float: false),
            ControlArgs(cmd: "htop", float: true, outliveParent: true),
        ] {
            XCTAssertEqual(error(try answer(.paneRun, args, from: lead))?.code, .badRequest, "\(args)")
        }
        XCTAssertEqual(everyPane(c).count, 1)
    }

    func test_aSplitFromAnAgentStillSplits() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)

        let split = try run(ControlArgs(cmd: "htop", split: .right), from: lead)

        XCTAssertFalse(isFloat(split, in: c))
        XCTAssertEqual(c.listing().workspaces.flatMap(\.tabs).first?.panes.map(\.token), [lead, split])
    }

    func test_focusShowsTheFloatAtOnce() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)

        let helper = try run(ControlArgs(cmd: "claude", focus: true), from: lead)

        XCTAssertTrue(c.floatsForTesting.shownSurface === (try surface(helper)))
    }

    func test_aFloatClosesWhenTheAgentAboveItExits_thoughItsPaneStaysOpen() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let helper = try run(ControlArgs(cmd: "claude", split: .right, keep: true), from: lead)
        let process = try run(ControlArgs(cmd: "htop"), from: helper)
        let tab = try run(ControlArgs(cmd: "htop", float: false), from: helper)
        XCTAssertTrue(isFloat(process, in: c), "precondition: an agent's run is a float")
        let quitting = try surface(helper)

        quitting.delegate?.surface(quitting, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))

        waitUntil(!isOpen(process, in: c), "the float closing with its agent")
        XCTAssertTrue(isOpen(helper, in: c))
        XCTAssertTrue(isOpen(tab, in: c), "a tab it started closed with the agent")
    }

    func test_closingATabNamesTheRunningFloatHiddenInIt() throws {
        let c = makeWindow()
        _ = try answer(.tabNew)
        let agentPane = try XCTUnwrap(everyPane(c).last?.token)
        try becomeAgent(agentPane)
        let helper = try run(ControlArgs(cmd: "claude", name: "review"), from: agentPane)
        try surface(helper).isBusy = true
        c.selectTab(try XCTUnwrap(c.pane(token: agentPane)?.tab))

        c.handle(.closeTab)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(
            toastTexts(in: c).contains("Closing this tab will stop everything running in it, including review."),
            "\(toastTexts(in: c))")
    }

    func test_closingAShownFloatsTabDoesNotNameIt() throws {
        let c = makeWindow()
        _ = try answer(.tabNew)
        let agentPane = try XCTUnwrap(everyPane(c).last?.token)
        try becomeAgent(agentPane)
        let helper = try run(ControlArgs(cmd: "claude", focus: true, name: "review"), from: agentPane)
        try surface(helper).isBusy = true

        c.handle(.closeTab)

        XCTAssertTrue(
            toastTexts(in: c).contains("Closing this tab will stop everything running in it."),
            "\(toastTexts(in: c))")
    }

    func test_aShownFloatPaneIsTheFocusedPane_forZenDraftsAndSeen() throws {
        let c = makeWindow()
        let drafts = PaneDrafts()
        c.paneDrafts = drafts
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        let program = try surface(float)
        let id = try XCTUnwrap(c.pane(token: float)?.pane.surfaceID)
        let leadID = try XCTUnwrap(c.pane(token: lead)?.pane.surfaceID)
        program.delegate?.surface(
            program, didPostNotification: TerminalNotification(title: "Claude Code", body: "Claude needs you"))
        drainMainQueue()

        try show(float, in: c)
        drainMainQueue()
        try sendKeys(typing: "q", to: c)

        let got = try XCTUnwrap(try answer(.paneGet).get() as? ListResult.Pane)
        XCTAssertEqual(got.token, float, "a request naming no pane reaches the pane on screen")
        XCTAssertTrue(drafts.isHolding(id))
        XCTAssertFalse(drafts.isHolding(leadID))
        XCTAssertEqual(c.surfaceAttentionForTesting(id), .idle)
    }

    func test_switchOnAHiddenFloatPanesCard_showsTheFloatInItsTab() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let home = try XCTUnwrap(c.pane(token: lead)?.tab)
        let float = try openFloat(in: c, beside: lead)
        let program = try surface(float)
        _ = try answer(.tabNew)
        let other = try XCTUnwrap(everyPane(c).last.flatMap { c.pane(token: $0.token)?.tab })
        c.selectTab(other)
        program.delegate?.surface(
            program, didPostNotification: TerminalNotification(title: "Claude Code", body: "Claude needs you"))
        drainMainQueue()
        let card = try XCTUnwrap(c.waitingToastForTesting(tab: home))

        let button = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == "Switch" })
        button.performClick(nil)
        drainMainQueue()

        XCTAssertEqual(c.activeTabIDForTesting, home)
        XCTAssertTrue(c.floatsForTesting.shownSurface === program)
        XCTAssertNil(c.waitingToastForTesting(tab: home), "showing the float answers its card")
    }

    func test_aFloatOpenedFromANeverShownTabStartsAtTheCardsSize_afterTheWindowResized() throws {
        let c = makeWindow()
        _ = try answer(.tabNew)
        let agentPane = try XCTUnwrap(everyPane(c).last?.token)
        try becomeAgent(agentPane)
        c.window.setContentSize(NSSize(width: 1300, height: 850))
        c.window.contentView?.layoutSubtreeIfNeeded()

        let helper = try run(ControlArgs(cmd: "claude"), from: agentPane)
        let hidden = try surface(helper).view.frame.size
        try show(helper, in: c)
        c.window.contentView?.layoutSubtreeIfNeeded()

        let shown = try surface(helper).view.frame.size
        XCTAssertGreaterThan(shown.width, 0)
        XCTAssertEqual(hidden.width, shown.width, accuracy: 1, "it starts at the card's size")
        XCTAssertEqual(hidden.height, shown.height, accuracy: 1, "it starts at the card's size")
    }

    func test_paneChordsOverAShownFloatPane_nameThePane() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        try tab(of: lead, in: c).updateRecord(pane: float) { $0.name = "review" }
        try show(float, in: c)

        c.handle(.navLeft)

        let texts = toastTexts(in: c)
        XCTAssertTrue(texts.contains("review is open. Close it to get back to your panes."), "\(texts)")
        XCTAssertTrue(texts.contains("Float Pane"), "\(texts)")
    }

    private func pressCommandW(in c: WindowController) throws {
        try pressChord("w", .command, keyCode: 13, in: c)
    }

    func test_cmdW_overAShownFloatPane_hidesIt_andItKeepsRunning() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        try show(float, in: c)

        try pressCommandW(in: c)

        XCTAssertNil(c.floatsForTesting.shownSurface)
        XCTAssertTrue(isOpen(float, in: c))
        XCTAssertFalse(try surface(float).terminated)
        XCTAssertTrue(isOpen(lead, in: c), "⌘W reached the pane under the float")
        XCTAssertFalse(c.isConfirmOpen)
    }

    func test_cmdW_overAToolFloat_hidesIt_andItKeepsRunning() throws {
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let scratch = try XCTUnwrap(c.floatsForTesting.shownSurface as? RecordingSurface)

        try pressCommandW(in: c)

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertFalse(scratch.terminated)
        XCTAssertTrue(isOpen(lead, in: c), "⌘W reached the pane under the float")
        XCTAssertTrue(toastTexts(in: c).isEmpty, "\(toastTexts(in: c))")
    }

    func test_cmdW_withNoFloatShown_stillClosesThePane() throws {
        let c = makeWindow()
        c.handle(.splitVertical)
        let panes = everyPane(c).count

        try pressCommandW(in: c)

        XCTAssertEqual(everyPane(c).count, panes - 1)
    }

    func test_aRemappedClosePane_hidesAShownFloatToo() throws {
        var config = GeneralConfig.current
        config.rebind(.closePane, to: Chord(command: true, control: true, key: "k"))
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        let lead = try token(of: XCTUnwrap(spawned.first))
        let float = try openFloat(in: c, beside: lead)
        try show(float, in: c)

        try pressChord("k", [.command, .control], keyCode: 40, in: c)

        XCTAssertNil(c.floatsForTesting.shownSurface)
        XCTAssertTrue(isOpen(float, in: c))
        XCTAssertTrue(isOpen(lead, in: c))
    }

    private func agentRow(of token: Int, in c: WindowController) throws -> SidebarAgentRow {
        let id = try XCTUnwrap(c.pane(token: token)?.pane.surfaceID)
        drainMainQueue()
        return try XCTUnwrap(c.sidebarForTesting.view.agentRowsForTesting.first { $0.itemForTesting?.id == id })
    }

    private func helperFloat(in c: WindowController) throws -> (lead: Int, helper: Int) {
        let lead = try token(of: XCTUnwrap(spawned.first))
        try becomeAgent(lead)
        return (lead, try run(ControlArgs(cmd: "claude", name: "review"), from: lead))
    }

    func test_clickingAFloatPanesRow_togglesIt() throws {
        let c = makeWindow()
        let family = try helperFloat(in: c)
        let row = try agentRow(of: family.helper, in: c)

        try sendClick(to: row)
        XCTAssertTrue(c.floatsForTesting.shownSurface === (try surface(family.helper)), "the first click shows it")

        try sendClick(to: row)
        XCTAssertNil(c.floatsForTesting.shownSurface, "the second click hides it")
        XCTAssertFalse(try surface(family.helper).terminated)

        try sendClick(to: row)
        XCTAssertTrue(c.floatsForTesting.shownSurface === (try surface(family.helper)))
    }

    func test_paneFocusOnAShownFloatPane_onlyShowsIt() throws {
        let c = makeWindow()
        let family = try helperFloat(in: c)

        _ = try answer(.paneFocus, ControlArgs(pane: .token(family.helper)))
        _ = try answer(.paneFocus, ControlArgs(pane: .token(family.helper)))

        XCTAssertTrue(c.floatsForTesting.shownSurface === (try surface(family.helper)))
    }

    private var rowMenu: SidebarRowMenu { controllers[0].sidebarForTesting.view.rowMenu }

    private func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], in c: WindowController) throws
        -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func rightClick(_ row: SidebarAgentRow, in c: WindowController) throws {
        row.rightMouseDown(with: try mouse(.rightMouseDown, in: c))
    }

    private func chooseClose(in c: WindowController) throws {
        let close = try XCTUnwrap(rowMenu.itemViewsForTesting.first { $0.title == "Close" })
        close.onChoose()
    }

    func test_rightClickControlClickAndSpace_openAnAgentRowsMenu_withClose() throws {
        let c = makeWindow()
        c.window.makeKeyAndOrderFront(nil)
        let family = try helperFloat(in: c)
        let row = try agentRow(of: family.helper, in: c)

        try rightClick(row, in: c)
        XCTAssertEqual(rowMenu.itemViewsForTesting.map(\.title), ["Close"])
        rowMenu.close()

        row.mouseDown(with: try mouse(.leftMouseDown, flags: .control, in: c))
        XCTAssertTrue(rowMenu.isOpen, "Control-click opens the menu")
        XCTAssertNil(c.floatsForTesting.shownSurface, "Control-click does not jump")
        rowMenu.close()

        c.window.makeFirstResponder(row)
        try sendKeys([.space], to: c)
        XCTAssertTrue(rowMenu.isOpen, "Space opens the menu")
        XCTAssertEqual(rowMenu.highlightedTitleForTesting, "Close")

        try sendKeys([.returnKey], to: c)
        XCTAssertFalse(isOpen(family.helper, in: c), "Return chose Close on an idle float pane")
    }

    func test_closeOnAnIdleFloatPane_closesItWithoutAsking() throws {
        let c = makeWindow()
        let family = try helperFloat(in: c)

        try rightClick(try agentRow(of: family.helper, in: c), in: c)
        try chooseClose(in: c)

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertFalse(isOpen(family.helper, in: c))
        XCTAssertTrue(isOpen(family.lead, in: c))
    }

    func test_closeOnARunningFloatPane_asksFirst() throws {
        let c = makeWindow()
        let family = try helperFloat(in: c)
        try surface(family.helper).isBusy = true

        try rightClick(try agentRow(of: family.helper, in: c), in: c)
        try chooseClose(in: c)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(
            toastTexts(in: c).contains("Closing this pane will stop the process running in it."),
            "\(toastTexts(in: c))")
        XCTAssertTrue(isOpen(family.helper, in: c))

        try pressConfirmClose(in: c)
        XCTAssertFalse(isOpen(family.helper, in: c))
        XCTAssertTrue(isOpen(family.lead, in: c))
    }

    func test_closeOnAParentWithARunningChild_namesTheChild() throws {
        let c = makeWindow()
        c.handle(.splitVertical)
        let parent = try XCTUnwrap(everyPane(c).last?.token)
        try becomeAgent(parent)
        let child = try run(ControlArgs(cmd: "claude", name: "review"), from: parent)
        try surface(child).isBusy = true

        try rightClick(try agentRow(of: parent, in: c), in: c)
        try chooseClose(in: c)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(
            toastTexts(in: c).contains("Closing this pane will stop the process running in it, including review."),
            "\(toastTexts(in: c))")
        XCTAssertTrue(isOpen(parent, in: c))

        try pressConfirmClose(in: c)
        XCTAssertFalse(isOpen(parent, in: c))
        waitUntil(!isOpen(child, in: c), "the child closing with its parent")
    }

    private func pressConfirmClose(in c: WindowController) throws {
        let content = try XCTUnwrap(c.window.contentView)
        let button = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? AppButton }.first { $0.title == "Close" })
        button.performClick(nil)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
