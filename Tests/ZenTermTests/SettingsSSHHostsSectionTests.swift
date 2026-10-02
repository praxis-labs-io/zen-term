import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SettingsSSHHostsSectionTests: WindowTestCase {
    private var configRoot: URL!
    private var sshConfig: URL!
    private var window: NSWindow?
    private var section: SettingsSSHHostsSection?

    override func setUpWithError() throws {
        try super.setUpWithError()
        configRoot = try makeTempDir()
        sshConfig = try makeTempDir().appendingPathComponent("config")
        ConfigLoader.defaultRootOverrideForTesting = configRoot
        SSHConfigHosts.userConfigOverrideForTesting = sshConfig
        SSHHostResolver.destinationOverrideForTesting = { _ in nil }
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        window = nil
        section = nil
        SSHConfigHosts.userConfigOverrideForTesting = nil
        SSHHostResolver.destinationOverrideForTesting = nil
        ConfigReset.toBuiltIn()
        try super.tearDownWithError()
    }

    private func seed(ssh: String?, config: String?) throws {
        if let ssh { try ssh.write(to: sshConfig, atomically: true, encoding: .utf8) }
        if let config {
            try config.write(to: configRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        AppConfig.reload()
    }

    private func configText() -> String {
        (try? String(contentsOf: configRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func rows(in view: NSView) -> [LayoutRow] {
        descendants(of: view).compactMap { $0 as? LayoutRow }
    }

    private func captions(in view: NSView) -> [String] {
        rows(in: view).compactMap { row in
            descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 13 }?.stringValue
        }
    }

    private func toggles(in view: NSView) -> [SegmentedControl] {
        descendants(of: view).compactMap { $0 as? SegmentedControl }
    }

    private func emptyHint(in view: NSView) -> NSTextField? {
        descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("No SSH hosts yet") }
    }

    @discardableResult
    private func mount(waitingForLoad: Bool = true) -> NSView {
        let section = SettingsSSHHostsSection()
        self.section = section
        let detail = section.makeDetailView()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(detail)
        detail.frame = win.contentView!.bounds
        window = win
        if waitingForLoad {
            waitUntil(!rows(in: detail).isEmpty || emptyHint(in: detail) != nil, "the hosts to load")
        }
        return detail
    }

    private func key(_ keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }

    private func arrow(_ keyCode: UInt16) -> NSEvent { key(keyCode, flags: [.function, .numericPad]) }

    private func press(_ event: NSEvent, on control: NSView) {
        window?.makeFirstResponder(control)
        control.keyDown(with: event)
    }

    private func settle() {
        let done = expectation(description: "deferred work ran")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func test_listsConfigHostsThenTypedHosts_showingWhichAreOn() throws {
        try seed(
            ssh: "Host devbox\nHost prod\n",
            config: "ssh-hosts = deploy@10.0.0.5, prod\n")

        let detail = mount()

        XCTAssertEqual(captions(in: detail), ["devbox", "prod", "deploy@10.0.0.5"])
        XCTAssertEqual(toggles(in: detail).map(\.selectedIndex), [1, 0, 0], "Off, On, On")
    }

    func test_whileLoading_showsNeitherRowsNorTheEmptyHint() throws {
        try seed(ssh: "Host devbox\n", config: nil)

        let detail = mount(waitingForLoad: false)

        XCTAssertTrue(rows(in: detail).isEmpty)
        XCTAssertNil(emptyHint(in: detail))
    }

    func test_noHostsAnywhere_showsTheEmptyHint() {
        let detail = mount()

        XCTAssertNotNil(emptyHint(in: detail))
        XCTAssertTrue(rows(in: detail).isEmpty)
    }

    func test_turningAHostOn_appendsItToTheConfig() throws {
        try seed(ssh: "Host devbox\nHost prod\n", config: "ssh-hosts = prod\n")
        let detail = mount()

        press(arrow(123), on: toggles(in: detail)[0])

        XCTAssertTrue(configText().contains("ssh-hosts = prod, devbox"), "got: \(configText())")
        XCTAssertEqual(GeneralConfig.current.sshHosts, ["prod", "devbox"])
    }

    func test_turningTheLastHostOff_removesTheKey() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-hosts = devbox\n")
        let detail = mount()

        press(arrow(124), on: toggles(in: detail)[0])

        XCTAssertFalse(configText().contains("ssh-hosts"), "got: \(configText())")
        XCTAssertEqual(GeneralConfig.current.sshHosts, [])
    }

    func test_delete_onATypedHost_removesItFromTheConfigAndTheList() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-hosts = devbox, deploy@10.0.0.5, ops@10.0.0.6\n")
        let detail = mount()

        press(key(51), on: toggles(in: detail)[1])
        settle()

        XCTAssertEqual(captions(in: detail), ["devbox", "ops@10.0.0.6"])
        XCTAssertEqual(GeneralConfig.current.sshHosts, ["devbox", "ops@10.0.0.6"])
        XCTAssertIdentical(window?.firstResponder, toggles(in: detail)[1], "focus moves to the row that took its place")
    }

    func test_forwardDelete_onTheLastTypedHost_movesFocusUp() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-hosts = deploy@10.0.0.5\n")
        let detail = mount()

        press(key(117, flags: [.function]), on: toggles(in: detail)[1])
        settle()

        XCTAssertEqual(captions(in: detail), ["devbox"])
        XCTAssertFalse(configText().contains("ssh-hosts"), "got: \(configText())")
        XCTAssertIdentical(window?.firstResponder, toggles(in: detail).first)
    }

    func test_delete_onAConfigHost_keepsIt() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-hosts = devbox\n")
        let detail = mount()

        press(key(51), on: toggles(in: detail)[0])
        settle()

        XCTAssertEqual(captions(in: detail), ["devbox"])
        XCTAssertEqual(GeneralConfig.current.sshHosts, ["devbox"])
    }

    func test_aResolvedDestination_showsUnderTheHost() throws {
        SSHHostResolver.destinationOverrideForTesting = { $0 == "devbox" ? "drew@10.0.0.2" : nil }
        try seed(ssh: "Host devbox\nHost prod\n", config: nil)

        let detail = mount()
        waitUntil(
            descendants(of: detail).contains { ($0 as? NSTextField)?.stringValue == "drew@10.0.0.2" },
            "the resolved destination to show")

        XCTAssertEqual(captions(in: detail), ["devbox", "prod"])
    }

    func test_addButton_asksForAHost() throws {
        let detail = mount()
        var asked = 0
        section?.onAddHost = { asked += 1 }
        let button = try XCTUnwrap(
            descendants(of: detail).compactMap { $0 as? AppButton }.first { $0.title == "＋ Add Host…" })

        press(key(36), on: button)

        XCTAssertEqual(asked, 1)
    }

    func test_addingAHost_fromSettings_turnsItOnAndListsItEverywhere() throws {
        let originalSurface = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { true }
        try seed(ssh: "Host devbox\n", config: nil)
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        defer {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            TerminalSurfaceFactory.makeOverride = originalSurface
        }
        c.mountAndStart()
        let content = try XCTUnwrap(c.window.contentView)
        c.openSettings(for: .setting(key: "ssh-hosts"))
        waitUntil(captions(in: content) == ["devbox"], "Settings to land on SSH Hosts")
        let add = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? AppButton }.first { $0.title == "＋ Add Host…" })

        add.onTap()
        let overlay = try XCTUnwrap(descendants(of: content).compactMap { $0 as? AddSSHHostOverlay }.first)
        let box = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? FieldBox }.first)
        box.setText("deploy@10.0.0.5")
        _ = box.control(box.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertTrue(configText().contains("ssh-hosts = deploy@10.0.0.5"), "got: \(configText())")
        waitUntil(
            captions(in: content) == ["devbox", "deploy@10.0.0.5"], "Settings to reopen listing the new host")
        XCTAssertEqual(toggles(in: content).map(\.selectedIndex), [1, 0])
        waitUntil(
            c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting) == ["deploy@10.0.0.5"],
            "the sidebar to list the new host")
    }
}
