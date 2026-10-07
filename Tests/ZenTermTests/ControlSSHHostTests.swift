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
