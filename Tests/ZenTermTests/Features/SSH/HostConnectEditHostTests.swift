import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class HostConnectEditHostTests: WindowTestCase {
    private let devbox = SSHHostID(alias: "devbox")
    private var configRoot: URL!
    private var originalSurface: (() -> TerminalSurface)?
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        configRoot = try makeTempDir()
        try "ssh-host = devbox: Build box\nssh-host = prod\n"
            .write(to: configRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        ConfigLoader.defaultRootOverrideForTesting = configRoot
        AppConfig.reload()
        originalSurface = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { true }
        WindowController.isPresent = { _ in true }
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controllers = []
        SSHHostStatusCenter.shared.setDestination(nil, host: devbox)
        TerminalSurfaceFactory.makeOverride = originalSurface
        WindowController.isPresent = originalPresence
        ConfigReset.toBuiltIn()
        try super.tearDownWithError()
    }

    private func onConnectScreen() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.activate(devbox)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func pressEditHost(in c: WindowController) throws {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { c.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "e",
                charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
        XCTAssertNil(keys.route(event), "the chord is claimed, not passed on")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func form(in c: WindowController) -> AddSSHHostOverlay? {
        c.window.contentView.flatMap { descendants(of: $0).compactMap { $0 as? AddSSHHostOverlay }.first }
    }

    private func settingsIsOpen(in c: WindowController) -> Bool {
        c.window.contentView.map { descendants(of: $0).contains { $0 is SettingsOverlay } } ?? false
    }

    private func fields(of form: AddSSHHostOverlay) -> [FieldBox] {
        descendants(of: form).compactMap { $0 as? FieldBox }
    }

    private func button(_ title: String, in view: NSView) throws -> AppButton {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? AppButton }.first { $0.title == title })
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func configText() -> String {
        (try? String(contentsOf: configRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    func test_theEditHostChordOnConnect_opensThatHostsEditForm() throws {
        SSHHostStatusCenter.shared.setDestination("drew@10.0.0.12", host: devbox)
        let c = onConnectScreen()

        try pressEditHost(in: c)

        let form = try XCTUnwrap(form(in: c), "⌘E on Connect edits the host")
        XCTAssertEqual(fields(of: form).map(\.text), ["devbox  drew@10.0.0.12", "Build box"], "with its address")
        XCTAssertFalse(settingsIsOpen(in: c))
    }

    func test_cancellingEditHostFromConnect_returnsToConnect_notSettings() throws {
        let c = onConnectScreen()
        try pressEditHost(in: c)
        let form = try XCTUnwrap(form(in: c))

        try button("Cancel", in: form).onTap()

        XCTAssertNil(self.form(in: c))
        XCTAssertFalse(settingsIsOpen(in: c))
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
    }

    func test_savingEditHostFromConnect_renamesTheHost_andReturnsToConnect() throws {
        let c = onConnectScreen()
        try pressEditHost(in: c)
        let form = try XCTUnwrap(form(in: c))

        fields(of: form)[1].setText("Builder")
        try button("Save", in: form).onTap()

        XCTAssertEqual(configText(), "ssh-host = devbox: Builder\nssh-host = prod\n")
        XCTAssertNil(self.form(in: c))
        XCTAssertFalse(settingsIsOpen(in: c))
        XCTAssertEqual(c.selectedHostForTesting, devbox)
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
    }

    func test_removingTheHostFromTheFormOpenedOnConnect_landsInSettings() throws {
        let c = onConnectScreen()
        try pressEditHost(in: c)
        let form = try XCTUnwrap(form(in: c))

        try button("Remove", in: form).onTap()
        let content = try XCTUnwrap(c.window.contentView)
        let card = try XCTUnwrap(descendants(of: content).compactMap { $0 as? ConfirmCard }.first)
        try button("Remove", in: card).onTap()

        XCTAssertEqual(configText(), "ssh-host = prod\n")
        XCTAssertNil(self.form(in: c))
        XCTAssertTrue(settingsIsOpen(in: c), "nothing is left on a Connect screen for a host that is gone")
    }

    func test_aConnectScreen_hidesAnAddressThatOnlyRepeatsTheAlias() throws {
        SSHHostStatusCenter.shared.setDestination("devbox", host: devbox)
        let c = onConnectScreen()
        let screen = try XCTUnwrap(c.connectViewForTesting)
        XCTAssertNil(screen.destinationForTesting, "the name already says devbox")

        SSHHostStatusCenter.shared.setDestination("drew@10.0.0.12", host: devbox)
        drainMainQueue()
        XCTAssertEqual(screen.destinationForTesting, "drew@10.0.0.12")
        SSHHostStatusCenter.shared.setDestination("devbox", host: devbox)
        drainMainQueue()

        XCTAssertNil(screen.destinationForTesting)
    }

    func test_theEditHostChord_inAWorkspace_stillSearchesTheSelection() throws {
        let c = onConnectScreen()
        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[0])

        try pressEditHost(in: c)

        XCTAssertNil(form(in: c), "outside Connect the chord keeps its own meaning")
    }
}
