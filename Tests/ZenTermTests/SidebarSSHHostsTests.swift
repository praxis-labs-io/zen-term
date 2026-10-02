import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SidebarSSHHostsTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []

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
        pin(hosts: [])
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controllers = []
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        SidebarController.resetLastChoiceForTesting()
        try super.tearDownWithError()
    }

    private func pin(hosts: [String]) {
        var config = GeneralConfig.builtIn
        config.ai = "pi"
        config.sshHosts = hosts
        GeneralConfig.setCurrentForTesting(config)
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func hostRows(_ c: WindowController) -> [SettingsNavRow] {
        c.sidebarForTesting.view.hostRowsForTesting
    }

    private func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags, in c: WindowController) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: c.window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    private func down(in c: WindowController) -> NSEvent {
        key(125, "\u{F701}", flags: [.function, .numericPad], in: c)
    }
    private func up(in c: WindowController) -> NSEvent { key(126, "\u{F700}", flags: [.function, .numericPad], in: c) }

    func test_hostsThatAreOn_listInTheSSHSection_inConfigOrder() {
        pin(hosts: ["prod", "deploy@10.0.0.5"])

        let c = makeWindow()

        XCTAssertEqual(hostRows(c).map(\.titleForTesting), ["prod", "deploy@10.0.0.5"])
        XCTAssertFalse(c.sidebarForTesting.view.hostsAreHiddenForTesting)
    }

    func test_noHosts_hidesTheSection() {
        let c = makeWindow()

        XCTAssertTrue(hostRows(c).isEmpty)
        XCTAssertTrue(c.sidebarForTesting.view.hostsAreHiddenForTesting)
    }

    func test_aConfigChange_bringsTheSectionUpAndTakesItDown() {
        let c = makeWindow()

        pin(hosts: ["devbox"])
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: ConfigChange.sshHosts])
        drainMainQueue()
        XCTAssertEqual(hostRows(c).map(\.titleForTesting), ["devbox"])

        pin(hosts: [])
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: ConfigChange.sshHosts])
        drainMainQueue()
        XCTAssertTrue(hostRows(c).isEmpty)
        XCTAssertTrue(c.sidebarForTesting.view.hostsAreHiddenForTesting)
    }

    func test_arrows_runFromWorkspacesThroughSSHIntoAgents() throws {
        pin(hosts: ["devbox", "prod"])
        let c = makeWindow()
        let agent = try XCTUnwrap(spawned.last)
        agent.delegate?.surface(
            agent, didPostNotification: TerminalNotification(title: "pi", body: "Wants to run swift test"))
        drainMainQueue()
        let workspace = try XCTUnwrap(c.sidebarForTesting.view.rowsForTesting.first)
        let hosts = hostRows(c)
        let agentRow = try XCTUnwrap(c.sidebarForTesting.view.agentRowsForTesting.first, "precondition")

        c.sidebarForTesting.focusActiveRow()
        XCTAssertTrue(c.window.firstResponder === workspace)
        c.window.sendEvent(down(in: c))
        XCTAssertTrue(c.window.firstResponder === hosts[0], "↓ leaves Workspaces for SSH")
        c.window.sendEvent(down(in: c))
        XCTAssertTrue(c.window.firstResponder === hosts[1])
        c.window.sendEvent(down(in: c))
        XCTAssertTrue(c.window.firstResponder === agentRow, "↓ leaves SSH for Agents")
        c.window.sendEvent(up(in: c))
        c.window.sendEvent(up(in: c))
        c.window.sendEvent(up(in: c))
        XCTAssertTrue(c.window.firstResponder === workspace, "↑ climbs back into Workspaces")
    }

    func test_return_onAHostRow_doesNothing() throws {
        pin(hosts: ["devbox"])
        let c = makeWindow()
        let active = c.sidebarForTesting.view.rowsForTesting.map { $0.titleForTesting }
        let surface = c.focusedSurfaceIDForTesting
        let recorder = KeyRecorder()
        recorder.nextResponder = c.window.nextResponder
        c.window.nextResponder = recorder

        XCTAssertTrue(c.sidebarForTesting.focusStop(.host("devbox")))
        c.window.sendEvent(key(36, "\r", flags: [], in: c))

        XCTAssertEqual(recorder.keyCodes, [], "Return is handled, so AppKit does not beep")

        XCTAssertTrue(c.window.firstResponder === hostRows(c).first, "focus stays on the host")
        XCTAssertEqual(c.sidebarForTesting.focusedStop, .host("devbox"))
        XCTAssertEqual(c.sidebarForTesting.view.rowsForTesting.map { $0.titleForTesting }, active)
        XCTAssertEqual(c.focusedSurfaceIDForTesting, surface)
    }

    private final class KeyRecorder: NSResponder {
        var keyCodes: [UInt16] = []
        override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
    }

    func test_aHostRow_refusesAWorktree() {
        pin(hosts: ["devbox"])
        let c = makeWindow()

        c.sidebarForTesting.focusStop(.host("devbox"))

        XCTAssertNil(c.sidebarForTesting.focusedWorktreeParent)
        XCTAssertEqual(c.sidebarForTesting.focusedWorktreeRefusal, .host)
    }

    func test_escape_onAHostRow_leavesTheSidebar() {
        pin(hosts: ["devbox"])
        let c = makeWindow()
        c.sidebarForTesting.focusStop(.host("devbox"))

        c.window.sendEvent(key(53, "\u{1b}", flags: [], in: c))

        XCTAssertFalse(c.sidebarForTesting.hasFocus)
    }
}
