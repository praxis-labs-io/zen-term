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

    private func removeButtons(in view: NSView) -> [AppButton] {
        rows(in: view).flatMap { row -> [AppButton] in
            let controls = descendants(of: row)
            if controls.contains(where: { $0 is SegmentedControl }) { return [] }
            return controls.compactMap { $0 as? AppButton }
        }
    }

    private func groupCaptions(in view: NSView) -> [String] {
        view.subviews.flatMap { child -> [String] in
            if child is LayoutRow { return [] }
            let own = (child as? NSTextField).flatMap { $0.font?.pointSize == 10 ? $0.stringValue : nil }
            return (own.map { [$0] } ?? []) + groupCaptions(in: child)
        }
    }

    private func label(_ text: String, in view: NSView) -> NSTextField? {
        descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
    }

    private func emptyHint(in view: NSView) -> NSTextField? {
        descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("No SSH hosts yet") }
    }

    private func rowCaption(_ row: LayoutRow) -> NSTextField? {
        descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 13 }
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

    private func key(_ keyCode: UInt16, flags: NSEvent.ModifierFlags = [], isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: isARepeat, keyCode: keyCode)!
    }

    private func arrow(_ keyCode: UInt16) -> NSEvent { key(keyCode, flags: [.function, .numericPad]) }

    private func press(_ event: NSEvent, on control: NSView) {
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: true)
        XCTAssertEqual(NSApp.currentEvent?.isARepeat, event.isARepeat, "the key event did not pin")
        window?.makeFirstResponder(control)
        control.keyDown(with: event)
    }

    private func settle() {
        let done = expectation(description: "deferred work ran")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func test_groupsConfigHostsWithOnOff_andAddedHostsWithRemove() throws {
        try seed(
            ssh: "Host devbox\nHost prod\n",
            config: "ssh-host = deploy@10.0.0.5\nssh-host = prod\n")

        let detail = mount()

        XCTAssertEqual(groupCaptions(in: detail), ["SSH CONFIG", "ADDED HOSTS"])
        XCTAssertEqual(captions(in: detail), ["devbox", "prod", "deploy@10.0.0.5"])
        XCTAssertEqual(toggles(in: detail).map(\.selectedIndex), [1, 0], "Off, On")
        let typedRow = try XCTUnwrap(rows(in: detail).last)
        XCTAssertTrue(descendants(of: typedRow).compactMap { $0 as? SegmentedControl }.isEmpty)
        XCTAssertEqual(removeButtons(in: detail).map(\.title), ["Remove"])
        XCTAssertNil(label("Couldn't read ~/.ssh/config.", in: detail))
    }

    func test_noConfigHosts_listsOnlyAddedHosts() throws {
        try seed(ssh: nil, config: "ssh-host = deploy@10.0.0.5\n")

        let detail = mount()

        XCTAssertEqual(groupCaptions(in: detail), ["ADDED HOSTS"])
        XCTAssertTrue(toggles(in: detail).isEmpty)
        XCTAssertNil(label("Couldn't read ~/.ssh/config.", in: detail), "a missing ~/.ssh/config is normal")
    }

    func test_noAddedHosts_listsOnlyConfigHosts() throws {
        try seed(ssh: "Host devbox\n", config: nil)

        let detail = mount()

        XCTAssertEqual(groupCaptions(in: detail), ["SSH CONFIG"])
        XCTAssertTrue(removeButtons(in: detail).isEmpty)
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
        XCTAssertEqual(groupCaptions(in: detail), ["SSH HOSTS"])
    }

    func test_anUnreadableSSHConfig_saysSo_andListsEnabledHostsAsAdded() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-host = devbox\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sshConfig.path)

        let detail = mount()

        XCTAssertEqual(groupCaptions(in: detail), ["SSH CONFIG", "ADDED HOSTS"])
        XCTAssertNotNil(label("Couldn't read ~/.ssh/config.", in: detail))
        XCTAssertEqual(captions(in: detail), ["devbox"])
        XCTAssertEqual(removeButtons(in: detail).map(\.title), ["Remove"])
    }

    func test_turningAHostOn_appendsItToTheConfig() throws {
        try seed(ssh: "Host devbox\nHost prod\n", config: "ssh-host = prod\n")
        let detail = mount()

        press(arrow(123), on: toggles(in: detail)[0])

        XCTAssertTrue(configText().contains("ssh-host = prod\nssh-host = devbox"), "got: \(configText())")
        XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["prod", "devbox"])
    }

    func test_turningTheLastHostOff_removesTheKey() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-host = devbox\n")
        let detail = mount()

        press(arrow(124), on: toggles(in: detail)[0])

        XCTAssertFalse(configText().contains("ssh-host"), "got: \(configText())")
        XCTAssertEqual(GeneralConfig.current.sshHostAliases, [])
    }

    func test_remove_writesTheHostOut_andKeepsTheRowFaintWithUndoFocused() throws {
        try seed(
            ssh: "Host devbox\n", config: "ssh-host = devbox\nssh-host = deploy@10.0.0.5\nssh-host = ops@10.0.0.6\n")
        let detail = mount()
        let button = removeButtons(in: detail)[0]
        let row = rows(in: detail)[1]

        press(key(36), on: button)
        settle()

        XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["devbox", "ops@10.0.0.6"])
        XCTAssertEqual(captions(in: detail), ["devbox", "deploy@10.0.0.5", "ops@10.0.0.6"])
        XCTAssertEqual(button.title, "Undo")
        XCTAssertTrue(row.isDimmed)
        XCTAssertEqual(rowCaption(row)?.textColor, Theme.current.chrome.ink(.faint))
        XCTAssertIdentical(window?.firstResponder, button)
        XCTAssertIdentical(removeButtons(in: detail).first, button, "the row is restyled in place, not rebuilt")
    }

    func test_undo_restoresTheHostAtItsOriginalPosition() throws {
        try seed(ssh: nil, config: "ssh-host = alpha\nssh-host = deploy@10.0.0.5\nssh-host = ops@10.0.0.6\n")
        let detail = mount()
        let button = removeButtons(in: detail)[1]
        let row = rows(in: detail)[1]

        press(key(36), on: button)
        press(key(36), on: button)

        XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["alpha", "deploy@10.0.0.5", "ops@10.0.0.6"])
        XCTAssertTrue(
            configText().contains("ssh-host = alpha\nssh-host = deploy@10.0.0.5\nssh-host = ops@10.0.0.6"), configText()
        )
        XCTAssertEqual(button.title, "Remove")
        XCTAssertFalse(row.isDimmed)
        XCTAssertEqual(rowCaption(row)?.textColor, Theme.current.chrome.foreground.nsColor)
        XCTAssertIdentical(window?.firstResponder, button)
        XCTAssertEqual(
            removeButtons(in: detail).map(\.title), ["Remove", "Remove", "Remove"], "no other host was removed")
    }

    func test_undo_restoresTheHostsName() throws {
        try seed(ssh: nil, config: "ssh-host = alpha\nssh-host = deploy@10.0.0.5: Deploy box\n")
        let detail = mount()
        let button = removeButtons(in: detail)[1]

        press(key(36), on: button)
        XCTAssertEqual(GeneralConfig.current.sshHosts, [SSHHostEntry(alias: "alpha")])
        press(key(36), on: button)

        XCTAssertEqual(
            GeneralConfig.current.sshHosts,
            [SSHHostEntry(alias: "alpha"), SSHHostEntry(alias: "deploy@10.0.0.5", name: "Deploy box")])
    }

    func test_turningAHostOffAndOnAgain_keepsItsName() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-host = devbox: Build box\n")
        let detail = mount()
        let toggle = toggles(in: detail)[0]

        press(arrow(124), on: toggle)
        XCTAssertEqual(GeneralConfig.current.sshHosts, [])
        press(arrow(123), on: toggle)

        XCTAssertEqual(GeneralConfig.current.sshHosts, [SSHHostEntry(alias: "devbox", name: "Build box")])
    }

    func test_undoingSeveralRemovals_inEitherOrder_restoresTheOriginalOrder() throws {
        for undoOrder in [[0, 1], [1, 0]] {
            try seed(ssh: nil, config: "ssh-host = alpha\nssh-host = beta\nssh-host = gamma\n")
            let detail = mount()
            let buttons = removeButtons(in: detail)

            press(key(36), on: buttons[0])
            press(key(36), on: buttons[1])
            XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["gamma"])
            for index in undoOrder { press(key(36), on: buttons[index]) }

            XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["alpha", "beta", "gamma"], "undo order \(undoOrder)")
        }
    }

    func test_aHeldReturn_doesNotFlipTheHostBack() throws {
        try seed(ssh: nil, config: "ssh-host = deploy@10.0.0.5\nssh-host = ops@10.0.0.6\n")
        let detail = mount()
        let button = removeButtons(in: detail)[0]

        press(key(36), on: button)
        for _ in 0..<2 {
            press(key(36, isARepeat: true), on: button)

            XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["ops@10.0.0.6"])
            XCTAssertEqual(button.title, "Undo")
        }
    }

    func test_aRemovedHost_staysRemovedWhenDestinationsResolve() throws {
        let gate = DispatchSemaphore(value: 0)
        SSHHostResolver.destinationOverrideForTesting = { host in
            gate.wait()
            return host == "ops" ? "drew@10.0.0.7" : nil
        }
        defer { (0..<8).forEach { _ in gate.signal() } }
        try seed(ssh: nil, config: "ssh-host = deploy@10.0.0.5\nssh-host = ops\n")
        let detail = mount()
        let button = removeButtons(in: detail)[0]
        press(key(36), on: button)

        (0..<2).forEach { _ in gate.signal() }
        waitUntil(label("drew@10.0.0.7", in: detail) != nil, "the resolved destination to rebuild the rows")

        let rebuilt = removeButtons(in: detail)
        XCTAssertFalse(rebuilt.contains { $0 === button }, "the rows were rebuilt")
        XCTAssertEqual(rebuilt.map(\.title), ["Undo", "Remove"])
        XCTAssertTrue(rows(in: detail)[0].isDimmed)
        XCTAssertIdentical(window?.firstResponder, rebuilt[0])
    }

    func test_aRemovedHost_isGoneNextTime() throws {
        try seed(ssh: nil, config: "ssh-host = deploy@10.0.0.5\nssh-host = ops@10.0.0.6\n")
        press(key(36), on: removeButtons(in: mount())[0])

        let reopened = mount()

        XCTAssertEqual(captions(in: reopened), ["ops@10.0.0.6"])
        XCTAssertEqual(removeButtons(in: reopened).map(\.title), ["Remove"])
    }

    func test_removeButton_namesItsHostForAccessibility() throws {
        try seed(ssh: nil, config: "ssh-host = deploy@10.0.0.5\n")
        let detail = mount()
        let button = removeButtons(in: detail)[0]

        XCTAssertEqual(button.accessibilityLabel(), "Remove deploy@10.0.0.5")
        press(key(36), on: button)
        XCTAssertEqual(button.accessibilityLabel(), "Undo removing deploy@10.0.0.5")
    }

    func test_aFailedRemove_saysSo_andLeavesTheRowAsItWas() throws {
        try seed(ssh: nil, config: "ssh-host = deploy@10.0.0.5\n")
        let detail = mount()
        let button = removeButtons(in: detail)[0]
        let row = rows(in: detail)[0]
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: configRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configRoot.path) }

        press(key(36), on: button)

        XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["deploy@10.0.0.5"])
        XCTAssertEqual(button.title, "Remove")
        XCTAssertFalse(row.isDimmed)
        XCTAssertTrue(
            row.renderedMessageForTesting?.hasPrefix("Couldn't save ZenTerm's config: ") == true,
            "got: \(row.renderedMessageForTesting ?? "nil")")
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

    private func addHostThroughSettings(_ host: String, ssh: String, check: (WindowController, NSView) throws -> Void)
        throws
    {
        let originalSurface = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { true }
        try seed(ssh: ssh, config: nil)
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        defer {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            TerminalSurfaceFactory.makeOverride = originalSurface
        }
        c.mountAndStart()
        let content = try XCTUnwrap(c.window.contentView)
        c.openSettings(for: .setting(key: "ssh-host"))
        waitUntil(!captions(in: content).isEmpty, "Settings to land on SSH Hosts")
        let add = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? AppButton }.first { $0.title == "＋ Add Host…" })

        add.onTap()
        let overlay = try XCTUnwrap(descendants(of: content).compactMap { $0 as? AddSSHHostOverlay }.first)
        let box = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? FieldBox }.first)
        box.setText(host)
        _ = box.control(box.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try check(c, content)
    }

    func test_addingAHost_fromSettings_listsItEverywhere_andFocusesIt() throws {
        try addHostThroughSettings("deploy@10.0.0.5", ssh: "Host devbox\n") { c, content in
            XCTAssertTrue(configText().contains("ssh-host = deploy@10.0.0.5"), "got: \(configText())")
            waitUntil(
                captions(in: content) == ["devbox", "deploy@10.0.0.5"], "Settings to reopen listing the new host")
            XCTAssertEqual(toggles(in: content).map(\.selectedIndex), [1])
            let remove = try XCTUnwrap(removeButtons(in: content).first)
            settle()
            XCTAssertIdentical(c.window.firstResponder, remove, "focus lands on the host just added")
            waitUntil(
                c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting) == ["deploy@10.0.0.5"],
                "the sidebar to list the new host")
        }
    }

    func test_addingAHostThatIsAnOffConfigHost_turnsItOn_andFocusesIt() throws {
        try addHostThroughSettings("prod", ssh: "Host devbox\nHost prod\n") { c, content in
            waitUntil(
                toggles(in: content).map(\.selectedIndex) == [1, 0], "Settings to reopen with prod turned on")
            settle()
            XCTAssertIdentical(c.window.firstResponder, toggles(in: content)[1], "focus lands on prod")
            XCTAssertTrue(removeButtons(in: content).isEmpty)
        }
    }
}
