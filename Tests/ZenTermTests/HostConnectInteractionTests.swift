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

    private func piRunningHiddenOnConnect() throws -> (WindowController, pi: RecordingSurface) {
        spawned = []
        let c = makeWindow()
        c.handle(.toggleToolFloat("pi"))
        let pi = try XCTUnwrap(spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "pi"] })
        c.handle(.toggleToolFloat("pi"))
        c.activate(host)
        return (c, pi)
    }

    private func ask(_ pi: RecordingSurface) {
        pi.delegate?.surface(pi, didPostNotification: TerminalNotification(title: "pi", body: "needs input"))
        drainMainQueue()
    }

    private func cards(in c: WindowController) -> [ToastView] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
    }

    private func runFromPalette(_ query: String, in c: WindowController) throws {
        c.handle(.toggleCommandPalette)
        let palette = try XCTUnwrap(
            descendants(of: try XCTUnwrap(c.window.contentView)).compactMap { $0 as? CommandPaletteOverlay }.first)
        let field = try XCTUnwrap(
            descendants(of: palette).compactMap { $0 as? NSTextField }.first { $0.delegate === palette })
        field.stringValue = query
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        _ = palette.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
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
        XCTAssertTrue(c.window.firstResponder === screen)
        XCTAssertEqual(screen.messageForTesting, "Connect to devbox")
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

        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
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
        XCTAssertTrue(c.window.firstResponder === screen)
        XCTAssertNotEqual(SSHHostStatusCenter.shared.status(of: host), .connected)
    }

    private func recordPanesAtMasterEnd() -> () -> [Bool] {
        var panesGone: [Bool] = []
        fake.onEnd = { [unowned self] in panesGone.append(spawned.allSatisfy(\.terminated)) }
        return { panesGone }
    }

    func test_closingAHostsLastPane_endsItsMaster_afterItsPanesAreGone() throws {
        let (c, _) = try connected()
        fake.connect(pid: 42)
        let panesGone = recordPanesAtMasterEnd()

        c.handle(.closePane)

        XCTAssertEqual(fake.ended, [42])
        XCTAssertEqual(panesGone(), [true], "ending the master first makes every live pane exit 255")
    }

    func test_closingTheWindow_endsAConnectedHostsMaster_afterItsPanesAreGone() throws {
        let (c, _) = try connected()
        c.handle(.newTab)
        fake.connect(pid: 42)
        let panesGone = recordPanesAtMasterEnd()

        c.tearDownForQuit()

        XCTAssertEqual(fake.ended, [42])
        XCTAssertEqual(panesGone(), [true])
    }

    private func pressDisconnect(in c: WindowController) throws {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { c.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "\u{17}",
                charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertNil(keys.route(event), "the chord is claimed, not passed to the pane")
    }

    func test_cmdCtrlW_onAConnectedHost_disconnectsWithoutAsking_evenWithSomethingRunning() throws {
        let (c, login) = try connected()
        fake.connect(pid: 42)
        login.isBusy = true

        try pressDisconnect(in: c)

        XCTAssertFalse(c.isConfirmOpen, "Disconnect is labeled and ↵ reconnects, so it never asks")
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertEqual(fake.ended, [42])
        XCTAssertTrue(login.terminated)
        XCTAssertNotEqual(SSHHostStatusCenter.shared.status(of: host), .connected)
        XCTAssertEqual(c.sidebarForTesting.hostIDs, [host], "the row stays")
    }

    func test_returnAfterDisconnecting_reconnects() throws {
        let (c, _) = try connected()
        fake.connect()
        try pressDisconnect(in: c)
        spawned = []
        fake.answerBeforeLogin = .some(nil)

        try press(36, "\r", in: c)
        fake.ready?()

        XCTAssertNil(c.connectViewForTesting)
        XCTAssertEqual(spawned.first?.startCount, 1, "a fresh login starts")
    }

    func test_thePaletteInAConnectedHost_disconnects() throws {
        let (c, _) = try connected()
        fake.connect(pid: 42)

        try runFromPalette("Disconnect", in: c)

        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertEqual(fake.ended, [42])
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

        c.activate(host)

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

    func test_aFloatThatNeedsYou_getsNoButtonInAHost_andItsShortcutOpensAndClosesIt() throws {
        let (c, pi) = try piRunningHiddenInAConnectedHost()

        ask(pi)

        XCTAssertFalse(dockShows("pi", in: c), "its card asks for it, not the host's dock")
        let spawnedBefore = spawned.count
        c.handle(.toggleToolFloat("pi"))

        XCTAssertTrue(c.floatsForTesting.shownSurface === pi, "the running float opens, nothing respawns")
        XCTAssertEqual(spawned.count, spawnedBefore)
        XCTAssertFalse(dockShows("pi", in: c), "an open float gets no button in a host either")

        c.handle(.toggleToolFloat("pi"))

        XCTAssertFalse(c.floatsForTesting.isOpen)
    }

    func test_aFloatThatIsOnlyWorking_staysHiddenInAHost_andItsShortcutToasts() throws {
        let (c, pi) = try piRunningHiddenInAConnectedHost()

        pi.delegate?.surface(pi, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()
        c.handle(.toggleToolFloat("pi"))

        XCTAssertFalse(dockShows("pi", in: c))
        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertTrue(showsToast("Tool floats run on this Mac, not on devbox.", in: c))
    }

    func test_aFloatThatFinished_getsNoButtonInAHost_andItsShortcutOpensIt() throws {
        var config = GeneralConfig.current
        config.ai = nil
        GeneralConfig.setCurrentForTesting(config)
        let (c, pi) = try piRunningHiddenInAConnectedHost()

        pi.delegate?.surface(pi, didPostNotification: TerminalNotification(title: "pi", body: "done"))
        drainMainQueue()
        XCTAssertFalse(dockShows("pi", in: c))

        c.handle(.toggleToolFloat("pi"))

        XCTAssertTrue(c.floatsForTesting.shownSurface === pi)
    }

    func test_theConnectScreen_hidesTheDock_andConnectingBringsItBack() throws {
        let c = onConnectScreen()

        XCTAssertEqual(c.dockForTesting.visibleLayoutForTesting, [])

        c.handle(.newTab)

        XCTAssertTrue(dockShows("New tab", in: c))
        XCTAssertTrue(dockShows("Scratch", in: c))
    }

    func test_aFloatThatNeedsYou_getsNoButtonOnConnect() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("pi"))
        let pi = try XCTUnwrap(spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "pi"] })
        c.handle(.toggleToolFloat("pi"))
        pi.delegate?.surface(pi, didPostNotification: TerminalNotification(title: "pi", body: "needs input"))
        drainMainQueue()

        c.activate(host)

        XCTAssertEqual(c.dockForTesting.visibleLayoutForTesting, [])
    }

    func test_aFloatAskingOverConnect_raisesItsCard_andLeavesTheDockEmpty() throws {
        let (c, pi) = try piRunningHiddenOnConnect()

        ask(pi)

        XCTAssertEqual(cards(in: c).count, 1)
        XCTAssertEqual(c.windowAttentionForTesting, .waiting)
        XCTAssertEqual(c.dockForTesting.visibleLayoutForTesting, [])
    }

    func test_aFloatsTurnEndingOverConnect_raisesItsCard() throws {
        let (c, pi) = try piRunningHiddenOnConnect()

        pi.delegate?.surface(pi, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()
        pi.delegate?.surface(pi, progressDidChange: nil)
        drainMainQueue()

        XCTAssertEqual(cards(in: c).count, 1)
        XCTAssertEqual(c.dockForTesting.visibleLayoutForTesting, [])
    }

    func test_aFloatsCardOnConnect_opensTheFloatOverConnect() throws {
        let (c, pi) = try piRunningHiddenOnConnect()
        ask(pi)
        let card = try XCTUnwrap(cards(in: c).first)
        let switchButton = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == "Switch" })

        switchButton.performClick(nil)
        drainMainQueue()

        XCTAssertTrue(c.floatsForTesting.shownSurface === pi)
        XCTAssertEqual(c.selectedHostForTesting, host)
        XCTAssertTrue(cards(in: c).isEmpty, "the card goes once you are looking at the float")
        XCTAssertEqual(c.windowAttentionForTesting, .idle)
    }

    func test_aFloatOverConnect_holdsTheKeyboard_andClosingItReturnsToConnect() throws {
        let (c, pi) = try piRunningHiddenOnConnect()
        ask(pi)
        let workspaces = c.workspaceIDsForTesting

        c.handle(.toggleToolFloat("pi"))
        XCTAssertTrue(c.window.firstResponder === pi.view)
        try press(36, "\r", in: c)

        XCTAssertEqual(c.workspaceIDsForTesting, workspaces, "Return belongs to the float, not Connect")
        XCTAssertNil(c.activeConnectionForTesting)

        c.handle(.toggleToolFloat("pi"))

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
        XCTAssertEqual(c.dockForTesting.visibleLayoutForTesting, [])
    }

    func test_aFloatChordOnConnect_opensAFloatThatNeedsYou_andIsSilentOtherwise() throws {
        let (c, pi) = try piRunningHiddenOnConnect()

        c.handle(.toggleToolFloat("pi"))

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertTrue(cards(in: c).isEmpty, "an inert command on Connect raises nothing")

        ask(pi)
        c.handle(.toggleToolFloat("pi"))

        XCTAssertTrue(c.floatsForTesting.shownSurface === pi)
    }

    func test_thePaletteInAHost_opensAFloatThatNeedsYou_andToastsForAnyOther() throws {
        let (c, pi) = try piRunningHiddenInAConnectedHost()

        try runFromPalette("pi", in: c)

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertTrue(showsToast("Tool floats run on this Mac, not on devbox.", in: c))

        ask(pi)
        try runFromPalette("pi", in: c)

        XCTAssertTrue(c.floatsForTesting.shownSurface === pi)
    }

    func test_thePaletteOnConnect_opensAFloatThatNeedsYou() throws {
        let (c, pi) = try piRunningHiddenOnConnect()
        ask(pi)

        try runFromPalette("pi", in: c)

        XCTAssertTrue(c.floatsForTesting.shownSurface === pi)
        XCTAssertEqual(c.selectedHostForTesting, host)
    }

    func test_aFloatThatNeedsYou_opensOverACardOnConnect_byItsShortcut() throws {
        for card: KeyInterceptor.ReservedChord in [.toggleCommandPalette, .openSettings] {
            let (c, pi) = try piRunningHiddenOnConnect()
            ask(pi)
            c.handle(card)
            XCTAssertTrue(c.isModalOverlayOpen)

            c.handle(.toggleToolFloat("pi"))

            XCTAssertFalse(c.isModalOverlayOpen, "\(card)")
            XCTAssertTrue(c.floatsForTesting.shownSurface === pi, "\(card)")
        }
    }

    func test_anInertFloatShortcutOnConnect_leavesTheCardOpen() throws {
        let (c, _) = try piRunningHiddenOnConnect()
        c.handle(.toggleCommandPalette)

        c.handle(.toggleToolFloat("pi"))

        XCTAssertTrue(c.isModalOverlayOpen)
        XCTAssertFalse(c.floatsForTesting.isOpen)
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
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting, file: file, line: line)
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

    private func quitAsks(in delegate: AppDelegate, _ c: WindowController) -> Bool {
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        defer { NSApp.reply(toApplicationShouldTerminate: false) }
        guard c.isConfirmOpen else { return false }
        try? press(button: "Cancel", in: c)
        return true
    }

    func test_quittingWithNothingOpenButAConnectScreen_doesNotAsk() throws {
        let delegate = AppDelegate()
        delegate.addWindowForTesting()
        let c = try XCTUnwrap(delegate.windowsForTesting.first)
        controllers.append(c)
        _ = try connect(c)
        fake.connect()
        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[0])
        c.handle(.closeTab)
        XCTAssertTrue(quitAsks(in: delegate, c), "precondition: a connected host's tab is something to close")

        c.handle(.closeWorkspace)

        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertFalse(quitAsks(in: delegate, c), "with no tab anywhere there is nothing to warn about")
        XCTAssertTrue(delegate.windowsForTesting.isEmpty, "quitting without asking still tears every window down")
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

    private func middleClickFirstTab(in c: WindowController) throws {
        let content = try XCTUnwrap(c.window.contentView)
        content.layoutSubtreeIfNeeded()
        let chip = try XCTUnwrap(
            descendants(of: content).first { String(describing: type(of: $0)) == "Chip" }, "no tab chip")
        let cg = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                mouseButton: .center))
        chip.otherMouseDown(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        drainMainQueue()
    }

    private func assertAbandonsTheLogin(
        _ c: WindowController, login: TerminalSurface, waiting: RecordingSurface?, asking message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(c.isConfirmOpen, "closing the login asks first, like a running process", file: file, line: line)
        XCTAssertTrue(showsToast(message, in: c), "the confirm says what goes", file: file, line: line)
        XCTAssertNil(c.connectViewForTesting, "nothing closes before the answer", file: file, line: line)

        try press(button: "Close", in: c)
        fake.connect()

        XCTAssertNotNil(c.connectViewForTesting, file: file, line: line)
        XCTAssertFalse(showsToast("Couldn't connect to devbox.", in: c), "the user closed it", file: file, line: line)
        XCTAssertEqual(waiting?.startCount ?? 0, 0, "waiting panes never start", file: file, line: line)
    }

    func test_closingTheLoginTab_whileConnecting_asksThenAbandonsQuietly() throws {
        let (c, login) = try connected()
        c.handle(.newTab)
        let waiting = spawned.last
        c.handle(.prevTab)

        c.handle(.closeTab)

        try assertAbandonsTheLogin(
            c, login: login, waiting: waiting,
            asking: "Closing this tab will stop connecting to devbox and close its tabs.")
    }

    func test_middleClickingTheLoginTab_whileConnecting_asksThenAbandonsQuietly() throws {
        let (c, login) = try connected()
        c.handle(.newTab)
        let waiting = spawned.last

        try middleClickFirstTab(in: c)

        try assertAbandonsTheLogin(
            c, login: login, waiting: waiting,
            asking: "Closing this tab will stop connecting to devbox and close its tabs.")
    }

    func test_disconnectingWhileConnecting_returnsToConnectAtOnce_withoutAFailureToast() throws {
        let (c, _) = try connected()
        c.handle(.newTab)
        let waiting = try XCTUnwrap(spawned.last)

        try pressDisconnect(in: c)
        fake.connect()

        XCTAssertFalse(c.isConfirmOpen, "Disconnect says what it does, so it never asks")
        XCTAssertNotNil(c.connectViewForTesting)
        XCTAssertFalse(showsToast("Couldn't connect to devbox.", in: c), "the user ended it")
        XCTAssertEqual(waiting.startCount, 0)
    }

    func test_closingTheLoginPane_saysTheHostsTabsGoToo() throws {
        let (c, login) = try connected()
        c.handle(.splitVertical)
        let waiting = spawned.last
        c.handle(.prevPane)

        c.handle(.closePane)

        try assertAbandonsTheLogin(
            c, login: login, waiting: waiting,
            asking: "Closing this pane will stop connecting to devbox and close its tabs.")
    }

    func test_closingADrawerThatBecameTheLoginAfterADrop_asksThenAbandonsQuietly() throws {
        let (c, _) = try connected()
        fake.connect()
        fake.exited?()
        fake.answerBeforeLogin = .some(nil)

        c.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(spawned.last)
        XCTAssertEqual(c.activeConnectionForTesting?.isAwaitingLogin(on: c.focusedSurfaceIDForTesting), true)
        c.handle(.closePane)

        try assertAbandonsTheLogin(
            c, login: drawer, waiting: nil,
            asking: "Closing this drawer will stop connecting to devbox and close its tabs.")
    }

    func test_theLoginCloseCopy_fitsTwoLinesOfTheToast() {
        func height(_ text: String) -> CGFloat {
            (text as NSString).boundingRect(
                with: NSSize(width: ToastView.messageMaxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: ToastView.messageFont]
            ).height
        }
        for target: CloseWarning.LoginTarget in [.pane, .drawer, .tab] {
            let message = CloseWarning.message(closing: .login(host: "devbox", closing: target), naming: [])
            XCTAssertLessThanOrEqual(height(message), height("One\nTwo"), message)
        }
    }

    private func halo(_ c: WindowController) throws -> Float {
        try XCTUnwrap(c.connectViewForTesting).panelForTesting.haloOpacityForTesting
    }

    private func postConfigChange(_ change: ConfigChange) {
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: change])
        drainMainQueue()
    }

    func test_connect_isFocusedAndHaloed_likeAPane() throws {
        let c = onConnectScreen()

        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
        XCTAssertGreaterThan(try halo(c), 0)
    }

    func test_connectsHalo_followsTheWindowsKeyState() throws {
        let c = onConnectScreen()

        c.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertEqual(try halo(c), 0)
        c.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertGreaterThan(try halo(c), 0)
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
    }

    func test_clickingConnect_fromTheSidebar_takesFocusAndTheHaloBack() throws {
        let c = onConnectScreen()
        c.handle(.focusSidebar)
        XCTAssertEqual(try halo(c), 0, "precondition: the sidebar holds focus")
        let panel = try XCTUnwrap(c.connectViewForTesting).panelForTesting
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        panel.mouseDown(with: event)

        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
        XCTAssertFalse(c.sidebarForTesting.hasFocus)
        XCTAssertGreaterThan(try halo(c), 0)
    }

    func test_aRevealedFloatingSidebar_takesConnectsHalo() throws {
        let c = onConnectScreen()
        c.window.setContentSize(c.window.contentMinSize)
        c.windowDidResize(Notification(name: NSWindow.didResizeNotification))

        c.handle(.toggleSidebar)
        XCTAssertTrue(c.sidebarForTesting.isRevealed, "precondition: too narrow to dock, so it floats")
        XCTAssertEqual(try halo(c), 0)
        c.handle(.toggleSidebar)

        XCTAssertGreaterThan(try halo(c), 0)
    }

    func test_connect_paintsTheTerminalBackground_andFollowsATranslucentOne() throws {
        let c = onConnectScreen()
        let panel = try XCTUnwrap(c.connectViewForTesting).panelForTesting
        XCTAssertEqual(panel.paintedBackgroundForTesting.fill, Theme.current.terminal.background.nsColor.cgColor)

        var config = GeneralConfig.current
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        postConfigChange(.terminalBehavior)

        XCTAssertNil(panel.paintedBackgroundForTesting.fill, "translucent, the ring paints instead of the fill")
        XCTAssertEqual(panel.paintedBackgroundForTesting.ring.alphaComponent, 0.5, accuracy: 0.01)
    }

    func test_theConnectButton_isTheFilledPrimaryButton_withNoOutlineOfItsOwn() throws {
        let c = onConnectScreen()
        let button = try XCTUnwrap(c.connectViewForTesting).connectButtonForTesting

        XCTAssertFalse(button.showsFocusOutline)
        XCTAssertFalse(button.acceptsFirstResponder, "the panel takes ↵, so the button never draws a focus ring")
        XCTAssertEqual(button.layer?.borderWidth, 0)
        XCTAssertNotNil(button.layer?.backgroundColor)
    }

    func test_leftFromConnect_movesToTheSidebar_andRightComesBack_withTheHalo() throws {
        let c = onConnectScreen()

        c.handle(.navLeft)
        XCTAssertTrue(c.sidebarForTesting.hasFocus, "Connect's left edge leads into the sidebar, as a pane's does")
        XCTAssertEqual(try halo(c), 0)
        c.handle(.navRight)

        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
        XCTAssertGreaterThan(try halo(c), 0)
    }

    func test_focusSidebarFromConnect_dropsTheHalo_andRightBringsItBack() throws {
        let c = onConnectScreen()

        c.handle(.focusSidebar)
        XCTAssertEqual(try halo(c), 0)
        c.handle(.navRight)

        XCTAssertGreaterThan(try halo(c), 0)
    }

    func test_upDownAndRightOnConnect_doNothing() throws {
        let c = onConnectScreen()

        for chord: KeyInterceptor.ReservedChord in [.navUp, .navDown, .navRight] {
            c.handle(chord)
            XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting, "\(chord) moved focus")
        }

        guard let content = c.window.contentView else { return XCTFail("no content") }
        XCTAssertFalse(
            descendants(of: content).contains { ($0 as? NSTextField)?.stringValue.hasPrefix("No pane") == true },
            "Connect has no neighbours, so there's nothing to say")
    }

    func test_leftFromConnect_withTheSidebarHidden_saysHowToShowIt_likeAPane() throws {
        let c = onConnectScreen()
        c.handle(.toggleSidebar)
        c.handle(.focusSidebar)
        c.handle(.toggleSidebar)
        XCTAssertFalse(c.sidebarForTesting.isShown, "precondition: the sidebar is hidden")
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)

        c.handle(.navLeft)

        let chord = CommandCatalog.spec(for: .toggleSidebar).shortcut
        XCTAssertTrue(showsToast("No pane left to focus\nPress \(chord) to show the sidebar.", in: c))
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
    }

    func test_fillScreen_worksOverConnect_andTogglesBack() throws {
        let c = onConnectScreen()
        let visible = try XCTUnwrap((c.window.screen ?? NSScreen.main)?.visibleFrame, "no screen to fill")
        let before = c.window.frame
        try XCTSkipIf(before == visible, "the window already fills the screen")

        c.handle(.fillScreen)
        XCTAssertEqual(c.window.frame.width, visible.width, accuracy: 1)
        XCTAssertEqual(c.window.frame.height, visible.height, accuracy: 1)
        c.handle(.fillScreen)

        XCTAssertEqual(c.window.frame.width, before.width, accuracy: 1)
        XCTAssertEqual(c.window.frame.height, before.height, accuracy: 1)
    }

    func test_connectLeadsWithALargeNeutralBadge() throws {
        let c = onConnectScreen()
        let screen = try XCTUnwrap(c.connectViewForTesting)
        let badge = try XCTUnwrap(descendants(of: screen).lazy.compactMap { $0 as? IconBadge }.first)
        let chrome = Theme.current.chrome

        XCTAssertEqual(badge.iconTintForTesting, chrome.muted.nsColor)
        XCTAssertEqual(badge.fillForTesting, chrome.tint(chrome.muted, alpha: ChromeTheme.badgeTint).cgColor)
        XCTAssertEqual(badge.fittingSize.width, IconBadge.Size.large.side)
    }
}
