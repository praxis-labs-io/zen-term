import AppKit
import ControlProtocol
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ControlSSHHostTests: WindowTestCase {
    private let host = SSHHostID(alias: "devbox")
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var raised: [WindowController] = []
    private var fake: FakeSSHWatchers!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        WindowController.isPresent = { _ in true }
        var config = GeneralConfig.builtIn
        config.sshHosts = [SSHHostEntry(alias: host.alias)]
        GeneralConfig.setCurrentForTesting(config)
        fake = FakeSSHWatchers()
        SSHConnection.watchersOverrideForTesting = fake.watchers
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controllers = []
        spawned = []
        SSHConnection.watchersOverrideForTesting = nil
        SSHHostStatusCenter.shared.setConnected(false, host: host)
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            initialCWD: FileManager.default.temporaryDirectory)
        controllers.append(c)
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private var responder: ControlResponder {
        var responder = ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first })
        responder.bringForward = { [unowned self] in raised.append($0) }
        responder.loadWorkspaces = { completion in completion([]) }
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

    private func loggingIn(_ c: WindowController) throws -> RecordingSurface {
        c.selectHostForTesting(host)
        spawned = []
        c.handle(.newTab)
        fake.ready?()
        c.window.contentView?.layoutSubtreeIfNeeded()
        return try XCTUnwrap(spawned.first, "connecting must spawn the login pane")
    }

    private func connected(_ c: WindowController) throws -> RecordingSurface {
        let login = try loggingIn(c)
        fake.connect()
        return login
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func address(_ c: WindowController, _ tab: TabID) -> String {
        ControlAddress.tab(window: c.windowID, tab: tab.raw)
    }

    private func showsFailureToast(_ c: WindowController) -> Bool {
        toastTexts(in: c).contains("Couldn't Connect to")
    }

    private func holdingOnlyTheHost(_ c: WindowController, login: () throws -> RecordingSurface) throws
        -> RecordingSurface
    {
        let local = c.activeWorkspaceIDForTesting
        let surface = try login()
        c.removeWorkspace(local)
        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
        return surface
    }

    func test_workspaceCloseOfAWindowsOnlyHost_disconnectsWithoutRefusing_andLandsOnConnect() throws {
        let c = makeWindow()
        let login = try holdingOnlyTheHost(c) { try connected(c) }

        _ = try result(send(.workspaceClose, from: token(of: login)), as: NoPayload.self)

        XCTAssertTrue(c.workspaceIDsForTesting.isEmpty)
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertNotNil(c.connectViewForTesting)
    }

    func test_workspaceCloseWhileConnecting_returnsToConnectWithoutAFailureToast() throws {
        let c = makeWindow()
        let login = try loggingIn(c)

        _ = try result(send(.workspaceClose, from: token(of: login)), as: NoPayload.self)
        drainMainQueue()

        XCTAssertNil(c.activeConnectionForTesting)
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertFalse(showsFailureToast(c))
    }

    func test_tabCloseOfTheLoginWhileConnecting_refusesNamingTheHost_thenForceAbandonsQuietly() throws {
        let c = makeWindow()
        _ = try loggingIn(c)
        let loginTab = try XCTUnwrap(c.activeTabIDForTesting)
        c.handle(.newTab)
        let tab = address(c, loginTab)

        let refusal = try error(send(.tabClose, ControlArgs(tab: tab)))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.message, "Closing tab \(tab) would stop connecting to devbox and close its 2 tabs.")
        XCTAssertEqual(refusal.details?.closesWindow, false)
        XCTAssertNotNil(c.activeConnectionForTesting)

        _ = try result(send(.tabClose, ControlArgs(tab: tab, force: true)), as: NoPayload.self)
        drainMainQueue()

        XCTAssertNil(c.activeConnectionForTesting)
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
        XCTAssertFalse(showsFailureToast(c))
    }

    func test_paneCloseOfTheLoginInASplitTab_refuses() throws {
        let c = makeWindow()
        let login = try token(of: loggingIn(c))
        _ = try result(send(.paneSplit, ControlArgs(pane: login, dir: .right)), as: PaneResult.self)

        let refusal = try error(send(.paneClose, ControlArgs(pane: login)))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.message, "Closing pane \(login) would stop connecting to devbox and close its tab.")
        XCTAssertNotNil(responder.locate(pane: login))
    }

    private let address = "ssh:devbox"

    func test_anSSHAddressFindsTheHostsWorkspaceInAnotherWindow_andSwitchRaisesIt() throws {
        _ = makeWindow()
        let there = makeWindow()
        let local = there.activeWorkspaceIDForTesting
        _ = try connected(there)
        let hostWorkspace = there.activeWorkspaceIDForTesting
        there.activateWorkspace(local)

        _ = try result(send(.workspaceSwitch, ControlArgs(workspace: address)), as: NoPayload.self)

        XCTAssertEqual(there.activeWorkspaceIDForTesting, hostWorkspace)
        XCTAssertTrue(raised.contains { $0 === there })
    }

    func test_anSSHAddressMatchesTheAliasNotTheName() throws {
        var config = GeneralConfig.current
        config.sshHosts = [SSHHostEntry(alias: host.alias, name: "Dev Box")]
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        let local = c.activeWorkspaceIDForTesting
        _ = try connected(c)
        c.activateWorkspace(local)

        for named in ["ssh:Dev Box", "Dev Box", "devbox"] {
            let refusal = try error(send(.workspaceSwitch, ControlArgs(workspace: named)))
            XCTAssertEqual(refusal.code, .notFound, named)
        }
        XCTAssertEqual(c.activeWorkspaceIDForTesting, local)
        _ = try result(send(.workspaceSwitch, ControlArgs(workspace: address)), as: NoPayload.self)
        XCTAssertNotNil(c.activeConnectionForTesting)
    }

    func test_aHostNotInSettingsIsNotFound_inEveryWorkspaceCommand() throws {
        let c = makeWindow()
        _ = try connected(c)
        let missing = ControlArgs(workspace: "ssh:nope", focus: true)

        for cmd in [ControlCommand.workspaceOpen, .workspaceSwitch, .workspaceClose, .tabNew] {
            let refusal = try error(send(cmd, missing))
            XCTAssertEqual(refusal.code, .notFound, cmd.rawValue)
            XCTAssertEqual(refusal.message, "There is no SSH host nope in Settings.", cmd.rawValue)
        }
        XCTAssertNotEqual(c.selectedHostForTesting, SSHHostID(alias: "nope"))
    }

    func test_aHostWithNoSession_isNotFound_forCommandsThatNeedItsWorkspace() throws {
        let c = makeWindow()
        let tabs = c.tabOrderForTesting

        for cmd in [ControlCommand.workspaceSwitch, .workspaceClose, .tabNew] {
            let refusal = try error(send(cmd, ControlArgs(workspace: address)))
            XCTAssertEqual(refusal.code, .notFound, cmd.rawValue)
            XCTAssertEqual(
                refusal.message,
                "ssh:devbox is not connected. workspace.open ssh:devbox --focus shows its Connect screen.")
        }
        XCTAssertEqual(c.tabOrderForTesting, tabs)
        XCTAssertNil(c.selectedHostForTesting)
    }

    func test_workspaceOpenOfAConnectedHost_returnsItsWorkspace_withoutASecondConnection() throws {
        let c = makeWindow()
        _ = try connected(c)
        let workspaces = c.workspaceIDsForTesting
        let resolves = fake.launchResolves

        let found = try result(send(.workspaceOpen, ControlArgs(workspace: address)), as: WorkspaceResult.self)
        let focused = try result(
            send(.workspaceOpen, ControlArgs(workspace: address, focus: true)), as: WorkspaceResult.self)

        XCTAssertEqual(found.window, ControlAddress.window(c.windowID))
        XCTAssertEqual(found.workspace?.title, "devbox")
        XCTAssertNil(found.connect)
        XCTAssertEqual(focused.workspace?.tabs.map(\.id), found.workspace?.tabs.map(\.id))
        XCTAssertEqual(c.workspaceIDsForTesting, workspaces)
        XCTAssertEqual(fake.launchResolves, resolves)
    }

    func test_workspaceOpenWithFocus_showsConnect_andNeverConnects() throws {
        let c = makeWindow()
        let surfaces = spawned.count

        let opened = try result(
            send(.workspaceOpen, ControlArgs(workspace: address, focus: true)), as: WorkspaceResult.self)

        XCTAssertEqual(
            opened, WorkspaceResult(window: ControlAddress.window(c.windowID), workspace: nil, connect: "devbox"))
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertNil(c.activeConnectionForTesting)
        XCTAssertEqual(fake.launchResolves, 0)
        XCTAssertEqual(spawned.count, surfaces)
        XCTAssertTrue(raised.contains { $0 === c })
    }

    func test_workspaceOpenOfAnUnconnectedHost_withoutFocus_refusesAndLeavesTheViewAlone() throws {
        let c = makeWindow()
        let showing = c.activeWorkspaceIDForTesting

        let refusal = try error(send(.workspaceOpen, ControlArgs(workspace: address)))

        XCTAssertEqual(refusal.code, .refused)
        XCTAssertEqual(refusal.message, "ssh:devbox is not connected. Add --focus to show its Connect screen.")
        XCTAssertNil(c.selectedHostForTesting)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, showing)
        XCTAssertTrue(raised.isEmpty)
    }

    func test_aCommandOrFolderForAHostTabOrSplit_isRefused() throws {
        let c = makeWindow()
        let login = try token(of: connected(c))
        let tabs = c.tabOrderForTesting
        let surfaces = spawned.count

        let refusals = try [
            error(send(.tabNew, ControlArgs(workspace: address, cmd: "make"))),
            error(send(.tabNew, ControlArgs(workspace: address, cwd: "/tmp"))),
            error(send(.paneSplit, ControlArgs(cmd: "make", pane: login, dir: .right))),
        ]

        XCTAssertEqual(refusals.map(\.code), [.refused, .refused, .refused])
        XCTAssertEqual(
            refusals[0].message, "A tab on ssh:devbox takes no cmd or cwd. It starts the host's login shell.")
        XCTAssertEqual(c.tabOrderForTesting, tabs)
        XCTAssertEqual(spawned.count, surfaces)
    }

    func test_aWorktreeCommandAddressedToAHost_saysWorktreesComeFromAConfiguredWorkspace() throws {
        let c = makeWindow()
        _ = try connected(c)

        let refusal = try error(send(.worktreeList, ControlArgs(workspace: address)))

        XCTAssertEqual(refusal.message, "ssh:devbox is an SSH host. Worktrees are made from a configured workspace.")
    }

    private func listedWorkspaces(_ c: WindowController) throws -> [ListResult.Workspace] {
        let list = try result(send(.list), as: ListResult.self)
        return try XCTUnwrap(list.windows.first { $0.id == ControlAddress.window(c.windowID) }).workspaces
    }

    func test_listPutsHostWorkspacesAfterTheLocalOnes_markedWithTheirHostAndState() throws {
        let c = makeWindow()
        _ = try loggingIn(c)
        let later = c.openUnconfiguredWorkspace(at: FileManager.default.temporaryDirectory)

        let connecting = try listedWorkspaces(c)
        fake.connect()
        let connected = try listedWorkspaces(c)

        XCTAssertEqual(connecting.count, 3)
        XCTAssertEqual(connecting.last?.title, "devbox")
        XCTAssertNil(connecting.last?.folder)
        XCTAssertEqual(connecting.last?.host, ListResult.Host(alias: "devbox", state: .connecting))
        XCTAssertEqual(connected.last?.host, ListResult.Host(alias: "devbox", state: .connected))
        XCTAssertEqual(connecting.dropLast().map(\.host), [nil, nil])
        XCTAssertEqual(connecting[1].title, c.listing(of: later)?.title)
        XCTAssertNotNil(connecting[1].folder)
        XCTAssertEqual(connected.last?.tabs.first?.panes.map(\.busy), [false])
    }

    func test_aHostWhoseLoginFailed_isLeftOutOfTheList() throws {
        let c = makeWindow()
        _ = try loggingIn(c)

        fake.unwatchable?()

        XCTAssertEqual(try listedWorkspaces(c).compactMap(\.host), [])
    }

    func test_tabNewOnAHost_startsOverSSHBehindTheView_atTheWindowsBackingScale() throws {
        let c = makeWindow()
        let login = try connected(c)
        let showing = c.activeTabIDForTesting

        _ = try result(send(.tabNew, from: token(of: login)), as: TabResult.self)

        let opened = try XCTUnwrap(spawned.last)
        XCTAssertFalse(opened === login)
        XCTAssertEqual(opened.lastConfig?.command, "/usr/bin/ssh")
        XCTAssertEqual(opened.lastConfig?.backingScale, c.window.backingScaleFactor)
        XCTAssertEqual(c.activeTabIDForTesting, showing)
    }
}
