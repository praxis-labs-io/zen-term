import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SSHHostNameTests: WindowTestCase {
    private let host = SSHHostID(alias: "devbox")
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
        name(host, "Build box")
        SSHHostStatusCenter.shared.setDestination("drew@10.0.1.12", host: host)
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
        SSHHostStatusCenter.shared.setDestination(nil, host: host)
        SSHHostStatusCenter.shared.setConnected(false, host: host)
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        SidebarController.resetLastChoiceForTesting()
        try super.tearDownWithError()
    }

    private func name(_ host: SSHHostID, _ name: String?) {
        var config = GeneralConfig.builtIn
        config.sshHosts = [SSHHostEntry(alias: host.alias, name: name)]
        GeneralConfig.setCurrentForTesting(config)
    }

    private func rename(_ name: String?) {
        self.name(host, name)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: ConfigChange.sshHosts])
        let drained = expectation(description: "main queue")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func onConnectScreen() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.selectHostForTesting(host)
        c.window.contentView?.layoutSubtreeIfNeeded()
        spawned = []
        return c
    }

    private func pressReturn(in c: WindowController) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        (c.window.firstResponder as? NSView)?.keyDown(with: event)
        fake.ready?()
        c.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func labels(_ c: WindowController) -> [String] {
        func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
        return descendants(of: c.window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    func test_aNamedHost_isShownByName_whileSSHConnectsWithItsAlias() throws {
        let c = onConnectScreen()
        let screen = try XCTUnwrap(c.connectViewForTesting)

        XCTAssertEqual(c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting), ["Build box"])
        XCTAssertEqual(c.sidebarForTesting.lead.workspaceNameForTesting, "Build box")
        XCTAssertEqual(screen.titleForTesting, "Connect to Build box")
        XCTAssertEqual(screen.connectButtonForTesting.accessibilityLabel(), "Connect to Build box")
        XCTAssertEqual(screen.detailForTesting, "Build box appears offline. Connect anyway?")
        XCTAssertEqual(screen.destinationForTesting, "drew@10.0.1.12", "the address line keeps the real address")
        XCTAssertEqual(c.window.title, "Build box")

        try pressReturn(in: c)

        XCTAssertEqual(spawned.first?.lastConfig?.args.suffix(2), ["devbox", SSHLaunch.loginShellCommand])
        XCTAssertEqual(c.window.title, "Build box")
        XCTAssertEqual(c.sidebarForTesting.lead.workspaceNameForTesting, "Build box")
    }

    func test_renamingAHost_relabelsTheConnectScreenLive_andClearingTheNameShowsTheAlias() throws {
        let c = onConnectScreen()
        let screen = try XCTUnwrap(c.connectViewForTesting)

        rename("Builder")

        XCTAssertIdentical(c.connectViewForTesting, screen, "the screen is relabelled in place")
        XCTAssertEqual(screen.titleForTesting, "Connect to Builder")
        XCTAssertEqual(screen.connectButtonForTesting.accessibilityLabel(), "Connect to Builder")
        XCTAssertEqual(screen.detailForTesting, "Builder appears offline. Connect anyway?")
        XCTAssertEqual(c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting), ["Builder"])
        XCTAssertEqual(c.sidebarForTesting.lead.workspaceNameForTesting, "Builder")
        XCTAssertEqual(c.window.title, "Builder")

        rename(nil)

        XCTAssertEqual(screen.titleForTesting, "Connect to devbox")
        XCTAssertEqual(c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting), ["devbox"])
        XCTAssertEqual(c.window.title, "devbox")
    }

    func test_renamingAConnectedHost_retitlesItsWindow() throws {
        let c = onConnectScreen()
        try pressReturn(in: c)

        rename("Builder")

        XCTAssertEqual(c.window.title, "Builder")
        XCTAssertEqual(c.sidebarForTesting.lead.workspaceNameForTesting, "Builder")
    }

    func test_toastsNameTheHost() throws {
        let c = onConnectScreen()
        try pressReturn(in: c)
        fake.connect()

        c.handle(.toggleToolFloat("pi"))

        XCTAssertTrue(labels(c).contains("Tool floats run on this Mac, not on Build box."), "\(labels(c))")
    }

    func test_aFailedLogin_namesTheHost() throws {
        let c = onConnectScreen()
        try pressReturn(in: c)
        let login = try XCTUnwrap(spawned.first)

        login.delegate?.surfaceDidExit(login, code: 255)
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertTrue(labels(c).contains(" Build box"), "\(labels(c))")
    }
}
