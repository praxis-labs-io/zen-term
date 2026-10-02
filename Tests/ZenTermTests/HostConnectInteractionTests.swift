import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class HostConnectInteractionTests: WindowTestCase {
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

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func onConnectScreen() -> WindowController {
        let c = makeWindow()
        c.selectHostForTesting(host)
        c.window.contentView?.layoutSubtreeIfNeeded()
        spawned = []
        return c
    }

    private func connected() throws -> (WindowController, login: RecordingSurface) {
        let c = onConnectScreen()
        c.handle(.newTab)
        fake.ready?()
        c.window.contentView?.layoutSubtreeIfNeeded()
        return (c, try XCTUnwrap(spawned.first, "connecting must spawn the login pane"))
    }

    private func press(_ keyCode: UInt16, _ characters: String, in c: WindowController) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        if c.window.contentView?.performKeyEquivalent(with: event) == true { return }
        (c.window.firstResponder as? NSView)?.keyDown(with: event)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func showsToast(_ message: String, in c: WindowController) -> Bool {
        guard let content = c.window.contentView else { return false }
        return descendants(of: content).contains { ($0 as? NSTextField)?.stringValue == message }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func test_aHostThatIsNotConnected_showsConnect_focused_withNoTabs() throws {
        let c = onConnectScreen()

        let screen = try XCTUnwrap(c.connectViewForTesting)
        XCTAssertTrue(c.window.firstResponder === screen.connectButton)
        XCTAssertEqual(screen.messageForTesting, "Press ↵ to connect to devbox.")
        XCTAssertEqual(c.tabOrderForTesting, [])
        XCTAssertEqual(c.window.title, "devbox")
    }

    func test_returnOnConnect_opensOneTab_whoseLoginPaneRunsSSH() throws {
        let c = onConnectScreen()

        try press(36, "\r", in: c)
        fake.ready?()

        XCTAssertNil(c.connectViewForTesting)
        XCTAssertEqual(c.tabOrderForTesting.count, 1)
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertEqual(spawned.count, 1)
        XCTAssertEqual(spawned[0].lastConfig?.command, "/usr/bin/ssh")
        XCTAssertEqual(spawned[0].lastConfig?.args.last, "devbox")
        XCTAssertEqual(c.window.title, "devbox")
    }

    func test_newTabOnConnect_connects() {
        let c = onConnectScreen()

        c.handle(.newTab)

        XCTAssertEqual(c.tabOrderForTesting.count, 1)
        XCTAssertNotNil(c.activeConnectionForTesting)
    }

    func test_chordsThatNeedATab_doNothingOnConnect() {
        let c = onConnectScreen()
        let before = c.workspaceIDsForTesting

        for chord: KeyInterceptor.ReservedChord in [
            .splitVertical, .splitHorizontal, .toggleBottomDrawer, .toggleRightDrawer, .closePane, .closeTab,
            .toggleToolFloat(ToolFloat.scratch.id),
        ] {
            c.handle(chord)
        }

        XCTAssertEqual(c.workspaceIDsForTesting, before)
        XCTAssertEqual(spawned.count, 0)
        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertNotNil(c.connectViewForTesting)
    }

    func test_aCardClosingChordOnConnect_leavesTheCardOpen() {
        let c = onConnectScreen()
        c.handle(.toggleCommandPalette)

        c.handle(.reportIssue)

        XCTAssertTrue(c.isModalOverlayOpen, "a chord the Connect screen drops must not close the palette on its way")
    }

    func test_rightArrowFromTheSidebar_focusesConnect() throws {
        let c = onConnectScreen()
        c.handle(.focusSidebar)
        XCTAssertTrue(c.sidebarForTesting.hasFocus)

        c.handle(.navRight)

        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting?.connectButton)
    }

    func test_whileConnecting_aNewPaneWaits_thenStartsOnceConnected() throws {
        let (c, login) = try connected()
        XCTAssertEqual(login.startCount, 1)

        c.handle(.splitVertical)
        c.handle(.toggleBottomDrawer)
        let waiting = Array(spawned.dropFirst())

        XCTAssertEqual(waiting.count, 2)
        XCTAssertTrue(waiting.allSatisfy { $0.startCount == 0 })
        fake.connect()
        XCTAssertTrue(waiting.allSatisfy { $0.startCount == 1 })
        XCTAssertEqual(SSHHostStatusCenter.shared.status(of: host), .connected)
    }

    func test_closingAHostsLastPane_returnsToConnect() throws {
        let (c, _) = try connected()
        fake.connect()
        let local = c.workspaceIDsForTesting

        c.handle(.closePane)

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertEqual(c.workspaceIDsForTesting.count, local.count - 1)
        let screen = try XCTUnwrap(c.connectViewForTesting)
        XCTAssertTrue(c.window.firstResponder === screen.connectButton)
        XCTAssertNotEqual(SSHHostStatusCenter.shared.status(of: host), .connected)
    }

    func test_closingTheLastLocalWorkspace_landsOnTheConnectedHost() throws {
        let (c, _) = try connected()
        fake.connect()
        let local = c.workspaceIDsForTesting[0]
        c.activateWorkspaceForTesting(local)

        c.closeTabForTesting(tab: c.tabIDsForTesting(workspace: local)[0])

        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertEqual(c.tabOrderForTesting.count, 1)
    }

    func test_aLoginThatEndsBeforeConnecting_returnsToConnect_andWarns() throws {
        let (c, login) = try connected()
        c.handle(.splitVertical)
        let waiting = try XCTUnwrap(spawned.last)

        login.delegate?.surfaceDidExit(login, code: 255)
        drainMainQueue()

        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertEqual(waiting.startCount, 0)
        XCTAssertTrue(showsToast("Couldn't connect to devbox.", in: c))
    }

    func test_reselectingAConnectedHost_landsOnItsWorkspace() throws {
        let (c, _) = try connected()
        let hostTabs = c.tabOrderForTesting
        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[0])

        c.activateHost(host)

        XCTAssertEqual(c.tabOrderForTesting, hostTabs)
        XCTAssertNil(c.connectViewForTesting)
    }

    func test_aToolFloatChordInAConnectedHost_toastsInsteadOfOpening() throws {
        let (c, _) = try connected()
        fake.connect()

        c.handle(.toggleToolFloat(ToolFloat.scratch.id))

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertTrue(showsToast("Tool floats run on this Mac, not on devbox.", in: c))
    }

    func test_theCollapsedLead_namesTheHost() {
        let c = onConnectScreen()

        XCTAssertEqual(c.sidebarForTesting.lead.workspaceNameForTesting, "devbox")
    }

    func test_theConnectFailure_breaksBeforeAHostTooLongForOneLine() {
        let font: [NSAttributedString.Key: Any] = [.font: ToastView.messageFont]
        let short = WindowController.connectFailedMessage(for: host)
        let long = WindowController.connectFailedMessage(
            for: SSHHostID(name: "build-runner-07.eu-west-2.compute.internal"))

        XCTAssertEqual(short, "Couldn't connect to devbox.")
        XCTAssertLessThanOrEqual((short as NSString).size(withAttributes: font).width, ToastView.messageMaxWidth)
        let lines = long.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Couldn't connect to")
        XCTAssertLessThanOrEqual((lines[0] as NSString).size(withAttributes: font).width, ToastView.messageMaxWidth)
    }

    func test_aLoginThatEndsBeforeConnecting_inItsOnlyPane_stillWarns() throws {
        let (c, login) = try connected()

        login.delegate?.surfaceDidExit(login, code: 255)
        drainMainQueue()

        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertTrue(showsToast("Couldn't connect to devbox.", in: c))
    }
}
