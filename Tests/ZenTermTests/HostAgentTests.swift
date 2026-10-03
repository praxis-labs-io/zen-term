import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class HostAgentTests: WindowTestCase {
    private let host = SSHHostID(name: "devbox")
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var fake: FakeSSHWatchers!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        SidebarController.resetLastChoiceForTesting()
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        WindowController.isPresent = { _ in true }
        var config = GeneralConfig.builtIn
        config.sshHosts = [host.name]
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
        SidebarController.resetLastChoiceForTesting()
        try super.tearDownWithError()
    }

    private struct Connected {
        let c: WindowController
        let local: WorkspaceID
        let login: RecordingSurface
        let loginID: SurfaceID
    }

    private func connected() throws -> Connected {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        let local = c.activeWorkspaceIDForTesting
        c.selectHostForTesting(host)
        spawned = []
        c.handle(.newTab)
        fake.ready?()
        fake.connect()
        c.window.contentView?.layoutSubtreeIfNeeded()
        let login = try XCTUnwrap(spawned.first, "connecting must spawn the login pane")
        let loginID = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        return Connected(c: c, local: local, login: login, loginID: loginID)
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func push(_ title: String, from surface: RecordingSurface) {
        surface.delegate?.surface(surface, titleDidChange: title)
        drainMainQueue()
    }

    private func progress(_ progress: TerminalProgress?, from surface: RecordingSurface) {
        surface.delegate?.surface(surface, progressDidChange: progress)
        drainMainQueue()
    }

    private func claudeWorking(on surface: RecordingSurface) {
        push("✳ Claude Code", from: surface)
        progress(TerminalProgress(state: .indeterminate), from: surface)
        push("◐ Reading", from: surface)
    }

    func test_aClaudeOnAHost_isListedUnderTheHost_andWorksFromItsProgress() throws {
        let host = try connected()

        claudeWorking(on: host.login)

        let row = try XCTUnwrap(host.c.agentRowForTesting(host.loginID))
        XCTAssertEqual(row.detail, "devbox · claude")
        XCTAssertEqual(row.state, .working)
    }

    func test_aTurnEndingOnAHostWhileAway_waits_andJumpingToTheWaitingAgentLandsOnIt() throws {
        let host = try connected()
        claudeWorking(on: host.login)
        host.c.activateWorkspaceForTesting(host.local)

        progress(nil, from: host.login)
        XCTAssertEqual(host.c.agentStateForTesting(host.loginID), .waiting)

        host.c.handle(.nextWaitingAgent)

        XCTAssertNotEqual(host.c.activeWorkspaceIDForTesting, host.local)
        XCTAssertEqual(host.c.focusedSurfaceIDForTesting, host.loginID)
        XCTAssertNil(host.c.agentWaitForTesting(host.loginID), "landing on it answers the turn end")
    }

    func test_aHostAgentClearingItsTitle_endsItsRow_andTakesDownItsWait() throws {
        let host = try connected()
        claudeWorking(on: host.login)
        host.c.activateWorkspaceForTesting(host.local)
        progress(nil, from: host.login)
        XCTAssertNotNil(host.c.agentWaitForTesting(host.loginID), "precondition: the turn end waits")

        push("", from: host.login)

        XCTAssertNil(host.c.agentRowForTesting(host.loginID))
        XCTAssertNil(host.c.agentWaitForTesting(host.loginID))
    }

    func test_aHostAgentLaunchedAgainAfterItsExit_getsAFreshRow() throws {
        let host = try connected()
        claudeWorking(on: host.login)
        push("", from: host.login)

        push("✳ Claude Code", from: host.login)

        XCTAssertEqual(host.c.agentRowForTesting(host.loginID)?.detail, "devbox · claude")
        XCTAssertEqual(host.c.agentRowForTesting(host.loginID)?.state, .idle)
    }

    func test_aClaudeInScratchOnAHost_endsWhenItsTitleClears() throws {
        let host = try connected()
        host.c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let scratch = try XCTUnwrap(spawned.last)
        let scratchID = try XCTUnwrap(host.c.floatsForTesting.surfaceID(ToolFloat.scratch.id))
        claudeWorking(on: scratch)
        XCTAssertEqual(host.c.agentRowForTesting(scratchID)?.state, .working, "precondition: Scratch is listed")

        push("", from: scratch)

        XCTAssertNil(host.c.agentRowForTesting(scratchID))
    }

    func test_aLocalAgentClearingItsTitle_keepsItsRow_soItsCrashStillAsks() throws {
        let host = try connected()
        host.c.activateWorkspaceForTesting(host.local)
        let localID = try XCTUnwrap(host.c.focusedSurfaceIDForTesting)
        let local = try XCTUnwrap(host.c.terminalSurfaceForTesting(localID) as? RecordingSurface)
        host.c.identifyAgentForTesting(localID, name: "claude")

        push("", from: local)
        XCTAssertNotNil(host.c.agentRowForTesting(localID), "a local exit waits for its command's result")
        local.delegate?.surface(local, commandDidFinish: TerminalCommandResult(exitCode: 1, duration: 1))
        drainMainQueue()

        XCTAssertEqual(host.c.agentWaitForTesting(localID), .ask)
    }
}
