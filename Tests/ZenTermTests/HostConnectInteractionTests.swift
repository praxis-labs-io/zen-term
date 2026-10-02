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
        config.floats = [Self.pi]
        config.ai = "pi"
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

    private static let pi = ToolFloat(
        id: "pi", order: 0, title: "pi", icon: ToolFloatParser.defaultIcon, command: "pi", dir: nil,
        widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: .window,
        toggle: Chord(command: true, shift: true, key: "b"))

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
        try connect(onConnectScreen())
    }

    private func connect(_ c: WindowController) throws -> (WindowController, login: RecordingSurface) {
        c.selectHostForTesting(host)
        spawned = []
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

    private func press(button title: String, in c: WindowController) throws {
        let content = try XCTUnwrap(c.window.contentView)
        let button = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? AppButton }.first { $0.title == title })
        button.performClick(nil)
        drainMainQueue()
    }

    private func piRunningHiddenInAConnectedHost() throws -> (WindowController, pi: RecordingSurface) {
        let c = makeWindow()
        c.handle(.toggleToolFloat("pi"))
        let pi = try XCTUnwrap(spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "pi"] })
        c.handle(.toggleToolFloat("pi"))
        _ = try connect(c)
        fake.connect()
        return (c, pi)
    }

    private func dockButton(_ label: String, in c: WindowController) -> IconButton? {
        descendants(of: c.dockForTesting).compactMap { $0 as? IconButton }.first { $0.accessibilityLabel() == label }
    }

    private func dockShows(_ label: String, in c: WindowController) -> Bool {
        c.dockForTesting.visibleLayoutForTesting.contains(label)
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

        c.handle(.toggleToolFloat("pi"))

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertTrue(showsToast("Tool floats run on this Mac, not on devbox.", in: c))
    }

    func test_scratchWhileConnecting_waitsForTheSharedConnection_thenStartsOverIt() throws {
        let (c, login) = try connected()

        _ = try XCTUnwrap(dockButton("Scratch", in: c)).accessibilityPerformPress()
        let scratch = try XCTUnwrap(spawned.last)

        XCTAssertFalse(scratch === login)
        XCTAssertTrue(c.floatsForTesting.shownSurface === scratch)
        XCTAssertEqual(scratch.startCount, 0)
        fake.connect()
        XCTAssertEqual(scratch.startCount, 1)
        XCTAssertEqual(scratch.lastConfig?.command, "/usr/bin/ssh")
        XCTAssertEqual(scratch.lastConfig?.args.last, "devbox")
        XCTAssertEqual(fake.socketWatches, 1, "Scratch rides the login's connection, so nothing asks again")
    }

    func test_scratchInAConnectedHost_startsAtOnceOverSSH() throws {
        let (c, _) = try connected()
        fake.connect()

        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let scratch = try XCTUnwrap(spawned.last)

        XCTAssertTrue(c.floatsForTesting.shownSurface === scratch)
        XCTAssertEqual(scratch.startCount, 1)
        XCTAssertEqual(scratch.lastConfig?.command, "/usr/bin/ssh")
        XCTAssertFalse(showsToast("Tool floats run on this Mac, not on devbox.", in: c))
    }

    func test_aScratchThatLogsInAfterADrop_andEndsFirst_failsTheConnection() throws {
        let (c, _) = try connected()
        fake.connect()
        fake.exited?()

        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let scratch = try XCTUnwrap(c.floatsForTesting.shownSurface as? RecordingSurface)
        let connection = try XCTUnwrap(c.activeConnectionForTesting)
        XCTAssertTrue(
            connection.isAwaitingLogin(on: c.floatsForTesting.surfaceID(ToolFloat.scratch.id)),
            "after a drop, Scratch is the surface that logs in again")
        scratch.delegate?.surfaceDidExit(scratch, code: 255)
        drainMainQueue()

        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertTrue(showsToast("Couldn't connect to devbox.", in: c))
    }

    func test_aConnectedHost_hidesYourToolFloatButtons_andALocalWorkspaceShowsThem() throws {
        let (c, _) = try connected()
        fake.connect()

        XCTAssertFalse(dockShows("pi", in: c))
        XCTAssertNotEqual(c.dockForTesting.visibleLayoutForTesting.last, "│")

        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[0])

        XCTAssertTrue(dockShows("pi", in: c))
    }

    func test_aFloatThatNeedsYou_keepsItsButtonInAHost_andTheButtonOpensIt() throws {
        let (c, pi) = try piRunningHiddenInAConnectedHost()
        XCTAssertFalse(dockShows("pi", in: c))

        pi.delegate?.surface(pi, didPostNotification: TerminalNotification(title: "pi", body: "needs input"))
        drainMainQueue()

        XCTAssertTrue(dockShows("pi", in: c))
        XCTAssertEqual(c.dockForTesting.dottedToolFloatIDsForTesting, ["pi"])
        let spawnedBefore = spawned.count
        _ = try XCTUnwrap(dockButton("pi", in: c)).accessibilityPerformPress()

        XCTAssertEqual(c.floatsForTesting.activeID, "pi")
        XCTAssertTrue(c.floatsForTesting.shownSurface === pi, "the running float opens, nothing respawns")
        XCTAssertEqual(spawned.count, spawnedBefore)
        XCTAssertTrue(dockShows("pi", in: c))

        c.handle(.toggleToolFloat("pi"))

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertFalse(dockShows("pi", in: c), "once answered and closed, it leaves the host's dock")
    }

    func test_aFloatThatIsOnlyWorking_staysHiddenInAHost() throws {
        let (c, pi) = try piRunningHiddenInAConnectedHost()

        pi.delegate?.surface(pi, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()

        XCTAssertFalse(dockShows("pi", in: c))
    }

    func test_aFloatThatFinished_keepsItsButtonInAHost() throws {
        var config = GeneralConfig.current
        config.ai = nil
        GeneralConfig.setCurrentForTesting(config)
        let (c, pi) = try piRunningHiddenInAConnectedHost()

        pi.delegate?.surface(pi, didPostNotification: TerminalNotification(title: "pi", body: "done"))
        drainMainQueue()

        XCTAssertTrue(dockShows("pi", in: c))
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

    func test_closingTheLoginWhileConnecting_asksFirst_andChangesNothingUntilAnswered() throws {
        let (c, login) = try connected()
        let tabs = c.tabOrderForTesting

        c.handle(.closePane)

        XCTAssertTrue(c.isConfirmOpen, "closing the login ends the connection, so it asks like a running pane")
        XCTAssertFalse(login.terminated)
        XCTAssertEqual(c.tabOrderForTesting, tabs)
    }

    func test_cancellingTheLoginClose_leavesTheLoginRunning() throws {
        let (c, login) = try connected()
        c.handle(.closePane)

        try press(button: "Cancel", in: c)

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertFalse(login.terminated)
        XCTAssertNil(c.connectViewForTesting)
        XCTAssertEqual(c.activeConnectionForTesting?.state, .connecting)
    }

    func test_confirmingTheLoginClose_returnsToConnect_withoutAFailureToast() throws {
        let (c, login) = try connected()
        c.handle(.splitVertical)
        let waiting = try XCTUnwrap(spawned.last)
        c.handle(.prevPane)
        XCTAssertTrue(c.focusedSurfaceForTesting === login, "precondition: the login pane has focus")
        c.handle(.closePane)

        try press(button: "Close", in: c)
        fake.connect()

        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertTrue(login.terminated)
        XCTAssertEqual(waiting.startCount, 0)
        XCTAssertFalse(showsToast("Couldn't connect to devbox.", in: c), "the user closed it; nothing failed")
    }

    func test_closingAWaitingPaneWhileConnecting_doesNotAsk() throws {
        let (c, _) = try connected()
        c.handle(.splitVertical)

        c.handle(.closePane)

        XCTAssertFalse(c.isConfirmOpen)
    }

    private func onlyAConnectedHost() throws -> WindowController {
        let (c, _) = try connected()
        fake.connect()
        let local = c.workspaceIDsForTesting[0]
        c.activateWorkspaceForTesting(local)
        c.handle(.closeTab)
        XCTAssertEqual(c.workspaceIDsForTesting.count, 1, "precondition: only the host's workspace is left")
        XCTAssertEqual(c.selectedHostForTesting, host)
        return c
    }

    private func assertBackOnConnect(_ c: WindowController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            c.isConfirmOpen, "a host close never takes the window, so it never asks to", file: file, line: line)
        XCTAssertTrue(c.window.isVisible, file: file, line: line)
        XCTAssertNotNil(c.connectViewForTesting, file: file, line: line)
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting?.connectButton, file: file, line: line)
    }

    func test_closingTheLastPaneOfAWindowsOnlyHost_returnsToConnectWithoutAsking() throws {
        let c = try onlyAConnectedHost()

        c.handle(.closePane)

        assertBackOnConnect(c)
    }

    func test_closingTheLastTabOfAWindowsOnlyHost_returnsToConnectWithoutAsking() throws {
        let c = try onlyAConnectedHost()

        c.handle(.closeTab)

        assertBackOnConnect(c)
    }

    func test_closingAWindowsOnlyHostWorkspace_returnsToConnectWithoutAsking() throws {
        let c = try onlyAConnectedHost()

        c.handle(.closeWorkspace)

        assertBackOnConnect(c)
    }

    func test_closingTheLocalWorkspaceBesideAHost_closesItWithoutAsking_andLandsOnTheHost() throws {
        let (c, _) = try connected()
        fake.connect()
        let local = c.workspaceIDsForTesting[0]
        c.activateWorkspaceForTesting(local)

        c.handle(.closePane)

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertFalse(c.workspaceIDsForTesting.contains(local))
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertNil(c.connectViewForTesting, "it lands on the connected host's panes")
    }
}
