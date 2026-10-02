import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlWorkspaceTabTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var configured: [Workspace] = []
    private var configReads = 0
    private var raised: [WindowController] = []
    private var appIsActive = true
    private let originalPresence = WindowController.isPresent
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zt-control-alpha")

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

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        var responder = ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first })
        responder.bringForward = { [unowned self] in raised.append($0) }
        responder.isInFront = { [unowned self] in appIsActive && $0 === controllers.first }
        responder.loadWorkspaces = { [unowned self] completion in
            configReads += 1
            completion(configured)
        }
        return responder
    }

    private func send(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int? = nil) throws
        -> ControlReply
    {
        var reply: ControlReply?
        responder.respond(
            to: ControlRequest(id: 1, cmd: cmd, args: args, caller: pane.map(ControlCaller.init(pane:)))
        ) { reply = $0 }
        return try XCTUnwrap(reply, "\(cmd.rawValue) never answered")
    }

    private func result<P>(_ reply: ControlReply, as: P.Type) throws -> P {
        try XCTUnwrap(try reply.get() as? P, "\(reply)")
    }

    private struct AnsweredOK: Error {}

    private func error(_ reply: ControlReply) throws -> ControlError {
        guard case .failure(let error) = reply else {
            XCTFail("expected an error, got \(reply)")
            throw AnsweredOK()
        }
        return error
    }

    private func token(of surface: RecordingSurface) throws -> Int {
        try XCTUnwrap(surface.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func address(_ c: WindowController, _ tab: TabID) -> String {
        ControlAddress.tab(window: c.windowID, tab: tab.raw)
    }

    private func alpha(tabs: [Workspace.Tab] = []) -> Workspace {
        Workspace(title: "alpha", path: folder, tabs: tabs, env: [:])
    }

    func test_tabNewFromAPaneAddsARunningTabToItsWorkspaceAndLeavesTheViewAlone() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let showing = try XCTUnwrap(c.activeTabIDForTesting)

        let opened = try result(
            send(.tabNew, ControlArgs(cmd: "npm run dev"), from: caller), as: TabResult.self)

        let newTab = try XCTUnwrap(c.tabOrderForTesting.last)
        XCTAssertEqual(opened.tab, address(c, newTab))
        XCTAssertEqual(opened.pane, try token(of: XCTUnwrap(spawned.last)))
        XCTAssertEqual(c.activeTabIDForTesting, showing)
        XCTAssertTrue(spawned.last?.lastConfig?.args.last?.contains("npm run dev") == true)
        let tabBar = try XCTUnwrap(descendants(of: c.containerForTesting).compactMap { $0 as? TabBarView }.first)
        XCTAssertEqual(tabBar.chipsForTesting.count, 2)
        XCTAssertTrue(raised.isEmpty)
    }

    func test_tabNewGoesToTheCallersWorkspaceWhenItIsInTheBackground() throws {
        let c = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let callerWorkspace = c.activeWorkspaceIDForTesting
        c.openWorkspaceForTesting(alpha())
        let showing = c.activeWorkspaceIDForTesting
        XCTAssertNotEqual(showing, callerWorkspace)

        _ = try result(send(.tabNew, from: caller), as: TabResult.self)

        XCTAssertEqual(c.tabIDsForTesting(workspace: callerWorkspace).count, 2)
        XCTAssertEqual(c.tabIDsForTesting(workspace: showing).count, 1)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, showing)
    }

    func test_tabNewStartsInTheCallersFolderUnlessGivenOne() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(spawned.first)
        first.currentDirectory = URL(fileURLWithPath: "/tmp/caller")

        _ = try result(send(.tabNew, from: try token(of: first)), as: TabResult.self)
        XCTAssertEqual(spawned.last?.lastConfig?.workingDirectory?.path, "/tmp/caller")

        _ = try result(send(.tabNew, ControlArgs(cwd: "/tmp/given"), from: try token(of: first)), as: TabResult.self)
        XCTAssertEqual(spawned.last?.lastConfig?.workingDirectory?.path, "/tmp/given")

        XCTAssertEqual(try error(send(.tabNew, ControlArgs(cwd: "relative"))).code, .badRequest)
        XCTAssertEqual(c.tabOrderForTesting.count, 3)
    }

    func test_tabNewWhileSettingsIsUpLeavesSettingsUp() throws {
        let c = makeWindow()
        c.handle(.openSettings)

        _ = try result(send(.tabNew), as: TabResult.self)

        XCTAssertTrue(c.isModalOverlayOpen)
    }

    func test_tabNewWithFocusShowsTheTab() throws {
        let c = makeWindow()

        let opened = try result(send(.tabNew, ControlArgs(focus: true)), as: TabResult.self)

        XCTAssertEqual(c.activeTabIDForTesting.map { address(c, $0) }, opened.tab)
        XCTAssertNotNil(spawned.last?.view.window)
    }

    func test_tabCloseRefusesARunningTabAndNamesItUntilForced() throws {
        let c = makeWindow()
        let opened = try result(send(.tabNew, ControlArgs(cmd: "npm run dev")), as: TabResult.self)
        let server = try XCTUnwrap(spawned.last)
        server.isBusy = true
        server.title = "npm run dev"

        let refusal = try error(send(.tabClose, ControlArgs(tab: opened.tab)))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertTrue(refusal.message.contains("npm run dev"), refusal.message)
        XCTAssertEqual(refusal.details?.panes.map(\.token), [opened.pane])
        XCTAssertEqual(refusal.details?.closesWindow, false)
        XCTAssertEqual(c.tabOrderForTesting.count, 2)

        _ = try result(send(.tabClose, ControlArgs(tab: opened.tab, force: true)), as: NoPayload.self)

        XCTAssertEqual(c.tabOrderForTesting.count, 1)
        XCTAssertTrue(server.terminated)
    }

    func test_tabCloseOfTheWindowsLastTabRefusesEvenWhenIdle() throws {
        let c = makeWindow()

        let refusal = try error(send(.tabClose))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.details?.closesWindow, true)
        XCTAssertEqual(c.tabOrderForTesting.count, 1)
    }

    func test_tabAddressesAreCheckedBeforeAnythingCloses() throws {
        let c = makeWindow()
        XCTAssertEqual(try error(send(.tabClose, ControlArgs(tab: "tab-one"))).code, .badRequest)
        XCTAssertEqual(try error(send(.tabClose, ControlArgs(tab: "w\(c.windowID).t99"))).code, .notFound)
        XCTAssertEqual(try error(send(.tabNew, from: Int.max)).code, .notFound, "a caller pane that is gone")
    }

    func test_tabSelectAndRenameActOnTheNamedTab() throws {
        let c = makeWindow()
        let opened = try result(send(.tabNew), as: TabResult.self)

        _ = try result(send(.tabRename, ControlArgs(tab: opened.tab, title: "server")), as: NoPayload.self)
        _ = try result(send(.tabSelect, ControlArgs(tab: opened.tab)), as: NoPayload.self)

        XCTAssertEqual(c.activeTabIDForTesting.map { address(c, $0) }, opened.tab)
        XCTAssertEqual(c.tabTitlesForTesting.last, "server")
        XCTAssertTrue(raised.isEmpty, "the key window is already in front")
        XCTAssertEqual(try error(send(.tabRename, ControlArgs(tab: opened.tab))).code, .badRequest)
    }

    func test_workspaceOpenReturnsOneOpenInAnotherWindowWithoutASecondCopy() throws {
        let here = makeWindow()
        let caller = try token(of: XCTUnwrap(spawned.first))
        let there = makeWindow()
        there.openWorkspaceForTesting(alpha())

        let found = try result(
            send(.workspaceOpen, ControlArgs(workspace: folder.path), from: caller), as: WorkspaceResult.self)

        XCTAssertEqual(found.window, ControlAddress.window(there.windowID))
        XCTAssertEqual(found.workspace.title, "alpha")
        XCTAssertEqual(here.workspaceIDsForTesting.count, 1)
        XCTAssertEqual(there.workspaceIDsForTesting.count, 2)
        XCTAssertEqual(configReads, 0, "an open workspace is found without reading the config")
    }

    func test_workspaceOpenOpensAConfiguredOneWithItsRecipeBehindTheView() throws {
        let c = makeWindow()
        let showing = c.activeWorkspaceIDForTesting
        configured = [alpha(tabs: [Workspace.Tab(name: "one"), Workspace.Tab(name: "two")])]

        let opened = try result(send(.workspaceOpen, ControlArgs(workspace: "alpha")), as: WorkspaceResult.self)

        XCTAssertEqual(opened.workspace.tabs.map(\.title), ["one", "two"])
        XCTAssertTrue(opened.workspace.configured)
        XCTAssertFalse(opened.workspace.active)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, showing)

        let again = try result(send(.workspaceOpen, ControlArgs(workspace: folder.path)), as: WorkspaceResult.self)
        XCTAssertEqual(again.workspace.tabs.map(\.id), opened.workspace.tabs.map(\.id), "returned, not duplicated")
        XCTAssertEqual(c.workspaceIDsForTesting.count, 2)
    }

    func test_workspaceOpenWithFocusSwitchesToIt() throws {
        let c = makeWindow()
        configured = [alpha()]

        let opened = try result(
            send(.workspaceOpen, ControlArgs(workspace: "alpha", focus: true)), as: WorkspaceResult.self)

        XCTAssertTrue(opened.workspace.active)
        XCTAssertEqual(c.workspaceNamesForTesting.last, "alpha")
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting.last)
    }

    func test_workspaceOpenOfAnSSHHostIsNotFoundWithoutReadingTheConfig() throws {
        _ = makeWindow()

        XCTAssertEqual(try error(send(.workspaceOpen, ControlArgs(workspace: "ssh:devbox"))).code, .notFound)
        XCTAssertEqual(try error(send(.workspaceOpen, ControlArgs(workspace: "nowhere"))).code, .notFound)
        XCTAssertEqual(configReads, 1)
    }

    func test_aTitleOpenInTwoWindowsIsAmbiguous() throws {
        _ = makeWindow()
        _ = makeWindow()

        XCTAssertEqual(try error(send(.workspaceSwitch, ControlArgs(workspace: "Workspace 1"))).code, .ambiguous)
    }

    func test_workspaceNewAppendsAnUnconfiguredWorkspaceAtThePath() throws {
        let c = makeWindow()
        let showing = c.activeWorkspaceIDForTesting

        let made = try result(send(.workspaceNew, ControlArgs(path: folder.path)), as: WorkspaceResult.self)

        XCTAssertEqual(made.workspace.title, "Workspace 2")
        XCTAssertEqual(made.workspace.folder, folder.path)
        XCTAssertFalse(made.workspace.configured)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, showing)
        XCTAssertEqual(try error(send(.workspaceNew, ControlArgs(path: "relative"))).code, .badRequest)
    }

    func test_workspaceSwitchMovesTheViewAndRaisesAnotherWindow() throws {
        let here = makeWindow()
        let there = makeWindow()
        there.openWorkspaceForTesting(alpha())
        there.activateWorkspaceForTesting(there.workspaceIDsForTesting[0])

        _ = try result(send(.workspaceSwitch, ControlArgs(workspace: "alpha")), as: NoPayload.self)

        XCTAssertEqual(there.workspaceNamesForTesting.last, "alpha")
        XCTAssertEqual(there.activeWorkspaceIDForTesting, there.workspaceIDsForTesting.last)
        XCTAssertTrue(raised.first === there)
        XCTAssertFalse(raised.contains { $0 === here })
    }

    func test_selectingATabInTheKeyWindowRaisesItWhileTheAppIsInTheBackground() throws {
        let c = makeWindow()
        let opened = try result(send(.tabNew), as: TabResult.self)
        appIsActive = false

        _ = try result(send(.tabSelect, ControlArgs(tab: opened.tab)), as: NoPayload.self)

        XCTAssertTrue(raised.first === c)
    }

    func test_withNoKeyWindowTheFrontmostWindowIsTheDefaultTarget() {
        let first = makeWindow()
        let second = makeWindow()

        XCTAssertTrue(AppDelegate.frontmost(of: controllers, in: [second.window, first.window]) === second)
        XCTAssertTrue(AppDelegate.frontmost(of: controllers, in: []) === first)
    }

    func test_workspaceCloseRefusesTheLastOneAndClosesABackgroundOneQuietly() throws {
        let c = makeWindow()
        XCTAssertEqual(try error(send(.workspaceClose)).details?.closesWindow, true)

        c.openWorkspaceForTesting(alpha())
        let showing = c.activeWorkspaceIDForTesting
        c.presentConfirm(variant: .warning, title: "Close Tab", message: "", confirmLabel: "Close") {}

        _ = try result(send(.workspaceClose, ControlArgs(workspace: "Workspace 1")), as: NoPayload.self)

        XCTAssertEqual(c.workspaceIDsForTesting, [showing])
        XCTAssertTrue(c.isConfirmOpen, "closing a workspace in the background leaves the confirm up")
    }

    func test_noCallerMeansTheKeyWindow() throws {
        let first = makeWindow()
        let second = makeWindow()

        _ = try result(send(.tabNew), as: TabResult.self)

        XCTAssertEqual(first.tabOrderForTesting.count, 2)
        XCTAssertEqual(second.tabOrderForTesting.count, 1)
    }
}
