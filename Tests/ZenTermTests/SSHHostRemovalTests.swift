import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SSHHostRemovalTests: WindowTestCase {
    private let devbox = SSHHostID(alias: "devbox")
    private let typed = SSHHostID(alias: "deploy@10.0.0.5")
    private var configRoot: URL!
    private var originalSurface: (() -> TerminalSurface)?
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var fake: FakeSSHWatchers!

    override func setUpWithError() throws {
        try super.setUpWithError()
        configRoot = try makeTempDir()
        try "ssh-host = devbox\nssh-host = prod\nssh-host = deploy@10.0.0.5\n"
            .write(to: configRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        ConfigLoader.defaultRootOverrideForTesting = configRoot
        AppConfig.reload()
        originalSurface = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { true }
        WindowController.isPresent = { _ in true }
        fake = FakeSSHWatchers()
        SSHConnection.watchersOverrideForTesting = fake.watchers
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controllers = []
        SSHConnection.watchersOverrideForTesting = nil
        for host in [devbox, typed] { SSHHostStatusCenter.shared.setConnected(false, host: host) }
        TerminalSurfaceFactory.makeOverride = originalSurface
        WindowController.isPresent = originalPresence
        ConfigReset.toBuiltIn()
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

    private func open(_ host: SSHHostID, in c: WindowController, connected: Bool = true) {
        c.activate(host)
        fake.answerBeforeLogin = .some(nil)
        c.handle(.newTab)
        fake.ready?()
        if connected { fake.connect(pid: 42) }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func openSettings(in c: WindowController) throws -> NSView {
        let content = try XCTUnwrap(c.window.contentView)
        c.openSettings(for: .setting(key: "ssh-host"))
        waitUntil(removeButtons(in: content).count == 3, "Settings to land on SSH Hosts")
        return content
    }

    private func removeButtons(in view: NSView) -> [AppButton] {
        descendants(of: view).compactMap { $0 as? AppButton }.filter { $0.title == "Remove" }
    }

    private func settings(in view: NSView) -> SettingsOverlay? {
        descendants(of: view).compactMap { $0 as? SettingsOverlay }.first
    }

    private func card(in view: NSView) -> ConfirmCard? {
        descendants(of: view).compactMap { $0 as? ConfirmCard }.first
    }

    private func texts(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func button(_ title: String, in view: NSView) throws -> AppButton {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? AppButton }.first { $0.title == title })
    }

    private func remove(_ button: AppButton, in c: WindowController) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 36))
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: true)
        c.window.makeFirstResponder(button)
        button.keyDown(with: event)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func test_removingAConnectedHost_warnsOverSettings_andChangesNothingUntilAnswered() throws {
        let c = makeWindow()
        open(devbox, in: c)
        let content = try openSettings(in: c)

        try remove(removeButtons(in: content)[0], in: c)

        let card = try XCTUnwrap(card(in: content), "an open host warns before it goes")
        XCTAssertTrue(texts(in: card).contains("Remove devbox"))
        XCTAssertTrue(
            texts(in: card).contains("Removing devbox will disconnect it and stop everything running in it."))
        XCTAssertNotNil(settings(in: content), "the warning keeps Settings open")
        XCTAssertTrue(GeneralConfig.current.sshHostAliases.contains("devbox"))
        XCTAssertTrue(c.holdsHost(devbox))
    }

    func test_cancellingTheWarning_keepsRemoveOnTheButton_andLeavesTheHostConnected() throws {
        let c = makeWindow()
        open(devbox, in: c)
        let content = try openSettings(in: c)
        let removeButton = removeButtons(in: content)[0]
        try remove(removeButton, in: c)

        try button("Cancel", in: XCTUnwrap(card(in: content))).onTap()
        drainMainQueue()

        XCTAssertNil(card(in: content))
        XCTAssertEqual(removeButton.title, "Remove")
        XCTAssertIdentical(c.window.firstResponder, removeButton)
        XCTAssertTrue(GeneralConfig.current.sshHostAliases.contains("devbox"))
        XCTAssertTrue(c.holdsHost(devbox))
        XCTAssertEqual(fake.ended, [])
    }

    func test_escapeOnTheWarning_cancelsIt_andKeepsSettingsOpen() throws {
        let c = makeWindow()
        open(devbox, in: c)
        let content = try openSettings(in: c)
        let removeButton = removeButtons(in: content)[0]
        try remove(removeButton, in: c)
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))

        _ = c.window.contentView?.performKeyEquivalent(with: escape)
        drainMainQueue()

        XCTAssertNil(card(in: content))
        XCTAssertNotNil(settings(in: content), "Esc answers the warning, not Settings")
        XCTAssertEqual(removeButton.title, "Remove")
    }

    func test_confirmingTheWarning_disconnects_andLandsOnTheNextRow_withSettingsStillOpen() throws {
        let c = makeWindow()
        open(devbox, in: c)
        let content = try openSettings(in: c)
        try remove(removeButtons(in: content)[0], in: c)

        try button("Remove", in: XCTUnwrap(card(in: content))).onTap()
        drainMainQueue()

        XCTAssertFalse(GeneralConfig.current.sshHostAliases.contains("devbox"))
        XCTAssertFalse(c.holdsHost(devbox))
        XCTAssertEqual(fake.ended, [42])
        XCTAssertNotEqual(c.selectedHostForTesting, devbox, "it lands where a removed host's Connect screen does")
        XCTAssertNotNil(settings(in: content))
        XCTAssertNil(card(in: content))
    }

    func test_removingAHostWhileItConnects_saysItStopsConnecting() throws {
        let c = makeWindow()
        open(devbox, in: c, connected: false)
        let content = try openSettings(in: c)

        try remove(removeButtons(in: content)[0], in: c)

        let card = try XCTUnwrap(card(in: content))
        XCTAssertTrue(texts(in: card).contains("Removing devbox will stop connecting to it and close its tabs."))
    }

    func test_removingAHostThatIsNotOpen_savesWithoutAsking() throws {
        let c = makeWindow()
        let content = try openSettings(in: c)

        try remove(removeButtons(in: content)[0], in: c)

        XCTAssertNil(card(in: content))
        XCTAssertFalse(GeneralConfig.current.sshHostAliases.contains("devbox"))
    }

    func test_aHostOpenInAnotherWindow_warnsHere_andDisconnectsThere() throws {
        let settingsWindow = makeWindow()
        let hostWindow = makeWindow()
        settingsWindow.hostSessionInAnyWindow = { [unowned hostWindow] in hostWindow.session(of: $0) }
        open(devbox, in: hostWindow)
        let content = try openSettings(in: settingsWindow)

        try remove(removeButtons(in: content)[0], in: settingsWindow)
        try button("Remove", in: XCTUnwrap(card(in: content))).onTap()
        drainMainQueue()

        XCTAssertFalse(hostWindow.holdsHost(devbox))
        XCTAssertEqual(fake.ended, [42])
    }

    func test_aConnectedHostRemoved_landsOnTheNextHostConnectedHere_pastAnOnlineOne() throws {
        let prod = SSHHostID(alias: "prod")
        SSHHostStatusCenter.shared.setReachable(true, host: prod)
        defer { SSHHostStatusCenter.shared.setReachable(false, host: prod) }
        let c = makeWindow()
        open(typed, in: c)
        open(devbox, in: c)

        try "ssh-host = prod\nssh-host = deploy@10.0.0.5\n".write(
            to: configRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
        drainMainQueue()

        XCTAssertEqual(c.selectedHostForTesting, typed, "devbox sat above prod, which is online but not connected")
        XCTAssertNil(c.connectViewForTesting, "it lands on the connected host's panes")
    }

    func test_aHostRemovedByEditingTheConfig_disconnects() throws {
        let c = makeWindow()
        open(devbox, in: c)

        try "ssh-host = prod\n".write(
            to: configRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
        drainMainQueue()

        XCTAssertFalse(c.holdsHost(devbox))
        XCTAssertEqual(fake.ended, [42])
        XCTAssertNotEqual(c.selectedHostForTesting, devbox, "no Connect screen is left for a host that is gone")
    }
}
