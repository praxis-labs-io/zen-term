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
        let float = owner.openFloatPane(running: program, cwd: nil)
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
}
