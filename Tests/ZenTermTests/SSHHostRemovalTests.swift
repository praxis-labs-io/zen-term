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
        waitUntil(hostRows(in: content).count == 3, "Settings to land on SSH Hosts")
        return content
    }

    private func hostRows(in view: NSView) -> [SSHHostRow] {
        descendants(of: view).compactMap { $0 as? SSHHostRow }
    }

    private func editForm(ofRow index: Int, in c: WindowController) throws -> AddSSHHostOverlay {
        let content = try XCTUnwrap(c.window.contentView)
        let row = try XCTUnwrap(hostRows(in: content)[index])
        row.onActivate?()
        return try XCTUnwrap(form(in: content))
    }

    private func form(in view: NSView) -> AddSSHHostOverlay? {
        descendants(of: view).compactMap { $0 as? AddSSHHostOverlay }.first
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

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func test_removingAConnectedHost_warnsOverTheForm_andChangesNothingUntilAnswered() throws {
        let c = makeWindow()
        open(devbox, in: c)
        let content = try openSettings(in: c)
        let form = try editForm(ofRow: 0, in: c)

        try button("Remove", in: form).onTap()

        let card = try XCTUnwrap(card(in: content), "an open host warns before it goes")
        XCTAssertTrue(texts(in: card).contains("Remove devbox"))
        XCTAssertTrue(
            texts(in: card).contains("Removing devbox will disconnect it and stop everything running in it."))
        XCTAssertNotNil(self.form(in: content), "the warning keeps the form open")
        XCTAssertTrue(GeneralConfig.current.sshHostAliases.contains("devbox"))
        XCTAssertTrue(c.holdsHost(devbox))
    }

    func test_cancellingTheWarning_keepsTheForm_focusesRemove_andLeavesTheHostConnected() throws {
        let c = makeWindow()
        open(devbox, in: c)
        let content = try openSettings(in: c)
        let form = try editForm(ofRow: 0, in: c)
        let remove = try button("Remove", in: form)
        remove.onTap()

        try button("Cancel", in: XCTUnwrap(card(in: content))).onTap()
        drainMainQueue()

        XCTAssertNil(card(in: content))
        XCTAssertNotNil(self.form(in: content))
        XCTAssertIdentical(c.window.firstResponder, remove)
        XCTAssertTrue(GeneralConfig.current.sshHostAliases.contains("devbox"))
        XCTAssertTrue(c.holdsHost(devbox))
        XCTAssertEqual(fake.ended, [])
    }

    func test_escapeOnTheWarning_cancelsIt_andKeepsTheFormOpen() throws {
        let c = makeWindow()
        open(devbox, in: c)
        let content = try openSettings(in: c)
        try button("Remove", in: editForm(ofRow: 0, in: c)).onTap()
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))

        _ = c.window.contentView?.performKeyEquivalent(with: escape)
        drainMainQueue()

        XCTAssertNil(card(in: content))
        XCTAssertNotNil(form(in: content), "Esc answers the warning, not the form")
        XCTAssertTrue(GeneralConfig.current.sshHostAliases.contains("devbox"))
    }

    func test_confirmingTheWarning_disconnects_andReturnsToSettingsOnTheNextRow() throws {
        let c = makeWindow()
        open(devbox, in: c)
        let content = try openSettings(in: c)
        try button("Remove", in: editForm(ofRow: 0, in: c)).onTap()

        try button("Remove", in: XCTUnwrap(card(in: content))).onTap()
        waitUntil(settings(in: content) != nil && form(in: content) == nil, "Settings to come back")
        drainMainQueue()

        XCTAssertFalse(GeneralConfig.current.sshHostAliases.contains("devbox"))
        XCTAssertFalse(c.holdsHost(devbox))
        XCTAssertEqual(fake.ended, [42])
        XCTAssertNotEqual(c.selectedHostForTesting, devbox, "it lands where a removed host's Connect screen does")
        let rows = hostRows(in: content)
        XCTAssertEqual(rows.map(\.host), ["prod", "deploy@10.0.0.5"])
        XCTAssertIdentical(c.window.firstResponder, rows[0])
    }

    func test_removingAHostWhileItConnects_saysItStopsConnecting() throws {
        let c = makeWindow()
        open(devbox, in: c, connected: false)
        let content = try openSettings(in: c)

        try button("Remove", in: editForm(ofRow: 0, in: c)).onTap()

        let card = try XCTUnwrap(card(in: content))
        XCTAssertTrue(texts(in: card).contains("Removing devbox will stop connecting to it and close its tabs."))
    }

    func test_removingAHostThatIsNotOpen_removesWithoutAsking_andFocusesTheRowBeforeWhenLast() throws {
        let c = makeWindow()
        let content = try openSettings(in: c)

        try button("Remove", in: editForm(ofRow: 2, in: c)).onTap()
        waitUntil(settings(in: content) != nil && form(in: content) == nil, "Settings to come back")
        drainMainQueue()

        XCTAssertNil(card(in: content))
        XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["devbox", "prod"])
        XCTAssertIdentical(c.window.firstResponder, hostRows(in: content)[1])
    }

    func test_removingTheOnlyHost_focusesAddHost() throws {
        try "ssh-host = devbox\n".write(
            to: configRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
        let c = makeWindow()
        let content = try XCTUnwrap(c.window.contentView)
        c.openSettings(for: .setting(key: "ssh-host"))
        waitUntil(hostRows(in: content).count == 1, "Settings to land on SSH Hosts")

        try button("Remove", in: editForm(ofRow: 0, in: c)).onTap()
        waitUntil(settings(in: content) != nil && form(in: content) == nil, "Settings to come back")
        drainMainQueue()

        XCTAssertEqual(hostRows(in: content).count, 0)
        let add = try button("＋ Add Host…", in: content)
        XCTAssertIdentical(c.window.firstResponder, add)
    }

    func test_aHostOpenInAnotherWindow_warnsHere_andDisconnectsThere() throws {
        let settingsWindow = makeWindow()
        let hostWindow = makeWindow()
        settingsWindow.hostSessionInAnyWindow = { [unowned hostWindow] in hostWindow.session(of: $0) }
        open(devbox, in: hostWindow)
        let content = try openSettings(in: settingsWindow)

        try button("Remove", in: editForm(ofRow: 0, in: settingsWindow)).onTap()
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
