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

    func test_aNamedHost_isListedByName_overItsAddress() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-host = devbox: Build box\nssh-host = deploy@10.0.0.5: Deploy\n")

        let detail = mount()

        XCTAssertEqual(captions(in: detail), ["Build box", "Deploy"])
        XCTAssertNotNil(label("devbox", in: detail))
        XCTAssertNotNil(label("deploy@10.0.0.5", in: detail))
        XCTAssertEqual(removeButtons(in: detail).first?.accessibilityLabel(), "Remove Deploy")
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

        XCTAssertEqual(configText(), "ssh-host-off = devbox\n")
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
        XCTAssertEqual(configText(), "ssh-host-off = devbox: Build box\n")
        press(arrow(123), on: toggle)

        XCTAssertEqual(GeneralConfig.current.sshHosts, [SSHHostEntry(alias: "devbox", name: "Build box")])
        XCTAssertEqual(configText(), "ssh-host = devbox: Build box\n")
    }

    func test_undoingTheRemovalOfAnOffHost_putsItBackOffAtItsPlace() throws {
        try seed(ssh: nil, config: "ssh-host-off = alpha\nssh-host-off = beta: Beta\nssh-host-off = gamma\n")
        let detail = mount()
        let button = removeButtons(in: detail)[1]

        press(key(36), on: button)
        XCTAssertEqual(configText(), "ssh-host-off = alpha\nssh-host-off = gamma\n")
        press(key(36), on: button)

        XCTAssertEqual(configText(), "ssh-host-off = alpha\nssh-host-off = beta: Beta\nssh-host-off = gamma\n")
        XCTAssertEqual(GeneralConfig.current.sshHostAliases, [])
    }

    func test_removingAHost_clearsAHandWrittenDuplicateOffLine_soTheNameCannotResurrect() throws {
        try seed(ssh: nil, config: "ssh-host = a\nssh-host-off = a: Old\n")

        try SSHHostsWriter.remove("a")
        XCTAssertEqual(configText(), "")
        AppConfig.reload()
        try SSHHostsWriter.add(SSHHostEntry(alias: "a"))
        AppConfig.reload()

        XCTAssertEqual(GeneralConfig.current.sshHosts, [SSHHostEntry(alias: "a")])
        XCTAssertEqual(configText(), "ssh-host = a\n")
    }

    func test_anOffHostKeepsItsName_acrossARestart() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-host = devbox: Build box\n")
        let detail = mount()
        press(arrow(124), on: toggles(in: detail)[0])

        GeneralConfig.setCurrentForTesting(.builtIn)
        AppConfig.reload()
        let reopened = mount()

        XCTAssertEqual(captions(in: reopened), ["Build box"])
        XCTAssertEqual(toggles(in: reopened).map(\.selectedIndex), [1])
        press(arrow(123), on: toggles(in: reopened)[0])
        XCTAssertEqual(GeneralConfig.current.sshHosts, [SSHHostEntry(alias: "devbox", name: "Build box")])
    }

    func test_anOffHostIsNotInTheSidebarList() throws {
        try seed(ssh: "Host devbox\nHost prod\n", config: "ssh-host = prod\nssh-host-off = devbox: Build box\n")

        XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["prod"])
        XCTAssertEqual(GeneralConfig.current.sshHostsOff, [SSHHostEntry(alias: "devbox", name: "Build box")])
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

    func test_aNamedHost_describesItselfByAlias_thenItsAddressWhenTheyDiffer() throws {
        SSHHostResolver.destinationOverrideForTesting = { host in
            ["devbox": "drew@10.0.0.2", "prod": "prod", "ops": "drew@10.0.0.3"][host]
        }
        try seed(
            ssh: "Host devbox\nHost prod\nHost ops\n",
            config: "ssh-host = devbox: Build box\nssh-host = prod: Production\nssh-host = ops\n")

        let detail = mount()
        waitUntil(label("drew@10.0.0.3", in: detail) != nil, "the resolved destinations to show")

        XCTAssertEqual(captions(in: detail), ["Build box", "Production", "ops"])
        XCTAssertNotNil(label("devbox · drew@10.0.0.2", in: detail))
        XCTAssertNotNil(label("prod", in: detail), "an address that is the alias is not repeated")
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

    private func inSettings(
        ssh: String, config: String?, _ body: (WindowController, NSView) throws -> Void
    ) throws {
        let originalSurface = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { true }
        try seed(ssh: ssh, config: config)
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        defer {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            TerminalSurfaceFactory.makeOverride = originalSurface
        }
        c.mountAndStart()
        let content = try XCTUnwrap(c.window.contentView)
        c.openSettings(for: .setting(key: "ssh-host"))
        waitUntil(!captions(in: content).isEmpty, "Settings to land on SSH Hosts")
        content.layoutSubtreeIfNeeded()
        try body(c, content)
    }

    private func addHostThroughSettings(
        _ host: String, name: String? = nil, ssh: String, check: (WindowController, NSView) throws -> Void
    ) throws {
        try inSettings(ssh: ssh, config: nil) { c, content in
            let add = try XCTUnwrap(
                descendants(of: content).compactMap { $0 as? AppButton }.first { $0.title == "＋ Add Host…" })

            add.onTap()
            let overlay = try XCTUnwrap(form(in: content))
            let boxes = descendants(of: overlay).compactMap { $0 as? FieldBox }
            boxes[0].setText(host)
            if let name { boxes[1].setText(name) }
            let addButton = try XCTUnwrap(
                descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Add" })
            c.window.makeFirstResponder(addButton)
            addButton.keyDown(with: key(36))
            try check(c, content)
        }
    }

    private func form(in content: NSView) -> AddSSHHostOverlay? {
        descendants(of: content).compactMap { $0 as? AddSSHHostOverlay }.first
    }

    private func formTitle(_ overlay: NSView) -> String? {
        descendants(of: overlay).compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 15 }?.stringValue
    }

    private func hostRows(in view: NSView) -> [SSHHostRow] {
        descendants(of: view).compactMap { $0 as? SSHHostRow }
    }

    private func click(_ view: NSView, in c: WindowController) throws -> NSView {
        let content = try XCTUnwrap(c.window.contentView)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let target = try XCTUnwrap(content.hitTest(point))
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        if let button = target as? NSButton {
            button.performClick(nil)
        } else {
            target.mouseDown(with: event)
        }
        return target
    }

    func test_addingAHost_fromSettings_listsItEverywhere_andFocusesIt() throws {
        try addHostThroughSettings("deploy@10.0.0.5", ssh: "Host devbox\n") { c, content in
            XCTAssertTrue(configText().contains("ssh-host = deploy@10.0.0.5"), "got: \(configText())")
            waitUntil(
                captions(in: content) == ["devbox", "deploy@10.0.0.5"], "Settings to reopen listing the new host")
            XCTAssertEqual(toggles(in: content).map(\.selectedIndex), [1])
            let remove = try XCTUnwrap(removeButtons(in: content).first)
            settle()
            XCTAssertIdentical(c.window.firstResponder, hostRows(in: content)[1], "focus lands on the host just added")
            XCTAssertNotNil(remove)
            waitUntil(
                c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting) == ["deploy@10.0.0.5"],
                "the sidebar to list the new host")
        }
    }

    func test_addingAHostWithAName_writesTheName_andListsItByName() throws {
        try addHostThroughSettings("deploy@10.0.0.5", name: "Deploy box", ssh: "Host devbox\n") { c, content in
            XCTAssertTrue(configText().contains("ssh-host = deploy@10.0.0.5: Deploy box\n"), "got: \(configText())")
            waitUntil(captions(in: content) == ["devbox", "Deploy box"], "Settings to reopen listing the host by name")
            waitUntil(
                c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting) == ["Deploy box"],
                "the sidebar to list the host by name")
        }
    }

    func test_addingAHostThatIsAnOffConfigHost_turnsItOn_andFocusesIt() throws {
        try addHostThroughSettings("prod", ssh: "Host devbox\nHost prod\n") { c, content in
            waitUntil(
                toggles(in: content).map(\.selectedIndex) == [1, 0], "Settings to reopen with prod turned on")
            settle()
            XCTAssertIdentical(c.window.firstResponder, hostRows(in: content)[1], "focus lands on prod")
            XCTAssertTrue(removeButtons(in: content).isEmpty)
        }
    }

    func test_aClickOnAHostRow_opensItsEditForm_forConfigAndAddedHosts() throws {
        try inSettings(ssh: "Host devbox\n", config: "ssh-host = devbox: Build box\nssh-host = deploy@10.0.0.5\n") {
            c, content in
            let devbox = try XCTUnwrap(rowCaption(rows(in: content)[0]))

            try click(devbox, in: c)

            let overlay = try XCTUnwrap(form(in: content))
            XCTAssertEqual(formTitle(overlay), "Edit SSH Host")
            let boxes = descendants(of: overlay).compactMap { $0 as? FieldBox }
            XCTAssertEqual(boxes.map(\.text), ["devbox", "Build box"])

            overlay.performKeyEquivalent(with: escape())
            waitUntil(form(in: content) == nil && !captions(in: content).isEmpty, "Settings to come back")
            content.layoutSubtreeIfNeeded()
            let deploy = try XCTUnwrap(rowCaption(rows(in: content)[1]))
            try click(deploy, in: c)

            let added = try XCTUnwrap(form(in: content))
            XCTAssertEqual(descendants(of: added).compactMap { $0 as? FieldBox }.map(\.text), ["deploy@10.0.0.5", ""])
        }
    }

    func test_aHostRow_isAButtonNamedForItsHost_thatOpensTheEditFormWhenPressed() throws {
        try inSettings(ssh: "", config: "ssh-host = deploy@10.0.0.5: Deploy box\n") { _, content in
            let row = try XCTUnwrap(hostRows(in: content).first)

            XCTAssertEqual(row.accessibilityRole(), .button)
            XCTAssertEqual(row.accessibilityLabel(), "Edit Deploy box")
            XCTAssertTrue(row.accessibilityPerformPress())

            XCTAssertEqual(formTitle(try XCTUnwrap(form(in: content))), "Edit SSH Host")
        }
    }

    func test_renamingAHostThatIsNoLongerListed_throws_ratherThanSavingNothing() {
        GeneralConfig.setCurrentForTesting(.builtIn)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try SSHHostsWriter.rename("gone", to: "Gone", configRoot: root)) {
            XCTAssertTrue($0 is SSHHostsWriter.NoLongerListed)
        }
    }

    func test_aClickOnAHostsToggle_turnsItOff_withoutOpeningTheForm() throws {
        try inSettings(ssh: "Host devbox\n", config: "ssh-host = devbox: Build box\n") { c, content in
            let off = try XCTUnwrap(
                descendants(of: toggles(in: content)[0]).compactMap { $0 as? AppButton }.first { $0.title == "Off" })

            let hit = try click(off, in: c)

            XCTAssertIdentical(hit, off)
            XCTAssertEqual(GeneralConfig.current.sshHostAliases, [])
            XCTAssertNil(form(in: content))
        }
    }

    func test_anOffHostsRow_opensItsEditForm_andRenamingWritesItsOffLine() throws {
        try inSettings(ssh: "Host devbox\nHost prod\n", config: "ssh-host = devbox\nssh-host-off = prod: Old\n") {
            c, content in
            let prod = try XCTUnwrap(rowCaption(rows(in: content)[1]))

            try click(prod, in: c)

            let overlay = try XCTUnwrap(form(in: content))
            XCTAssertEqual(formTitle(overlay), "Edit SSH Host")
            let boxes = descendants(of: overlay).compactMap { $0 as? FieldBox }
            XCTAssertEqual(boxes.map(\.text), ["prod", "Old"])
            boxes[1].setText("Production")
            let save = try XCTUnwrap(
                descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Save" })
            c.window.makeFirstResponder(save)
            save.keyDown(with: key(36))

            XCTAssertEqual(configText(), "ssh-host = devbox\nssh-host-off = prod: Production\n")
            waitUntil(form(in: content) == nil && !captions(in: content).isEmpty, "Settings to come back")
            XCTAssertEqual(captions(in: content), ["devbox", "Production"])
        }
    }

    func test_saveWritesTheName_andClearingItRemovesTheName() throws {
        try inSettings(ssh: "Host devbox\n", config: "ssh-host = devbox  # the build box\n") { c, content in
            for (typed, line) in [
                ("Builder", "ssh-host = devbox: Builder  # the build box\n"),
                ("", "ssh-host = devbox  # the build box\n"),
            ] {
                let row = try XCTUnwrap(hostRows(in: content).first)
                press(key(36), on: row)
                let overlay = try XCTUnwrap(form(in: content))
                descendants(of: overlay).compactMap { $0 as? FieldBox }[1].setText(typed)
                let save = try XCTUnwrap(
                    descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Save" })
                c.window.makeFirstResponder(save)
                save.keyDown(with: key(36))

                XCTAssertEqual(configText(), line)
                waitUntil(form(in: content) == nil && !captions(in: content).isEmpty, "Settings to come back")
                XCTAssertEqual(captions(in: content), [typed.isEmpty ? "devbox" : typed])
                settle()
                XCTAssertIdentical(c.window.firstResponder, hostRows(in: content).first, "focus is back on the host")
            }
        }
    }

    func test_keyboard_returnOpensTheForm_rightReachesTheControl_andLeftComesBack() throws {
        try seed(ssh: "Host devbox\nHost prod\n", config: "ssh-host = devbox: Build box\nssh-host = ops@10.0.0.6\n")
        let detail = mount()
        var edited: [SSHHostEntry] = []
        section?.onEditHost = { host, _ in edited.append(host) }
        let rows = hostRows(in: detail)
        let toggle = toggles(in: detail)[0]
        let remove = removeButtons(in: detail)[0]

        XCTAssertEqual(
            section?.detailStops().map(ObjectIdentifier.init),
            [rows[0], toggle, rows[1], toggles(in: detail)[1], rows[2], remove].map(ObjectIdentifier.init)
                + (section?.detailStops().suffix(1).map(ObjectIdentifier.init) ?? []))

        press(key(36), on: rows[0])
        XCTAssertEqual(edited, [SSHHostEntry(alias: "devbox", name: "Build box")])

        press(arrow(124), on: rows[0])
        XCTAssertIdentical(window?.firstResponder, toggle)
        XCTAssertEqual(toggle.selectedIndex, 0, "reaching the toggle does not flip it")
        press(arrow(123), on: toggle)
        XCTAssertIdentical(window?.firstResponder, rows[0])
        XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["devbox", "ops@10.0.0.6"])

        press(arrow(125), on: rows[0])
        XCTAssertIdentical(window?.firstResponder, rows[1], "the Off host's row is a stop")
        press(arrow(124), on: rows[1])
        XCTAssertIdentical(window?.firstResponder, toggles(in: detail)[1])
        press(arrow(125), on: toggles(in: detail)[1])
        XCTAssertIdentical(window?.firstResponder, remove, "down from a control stays in the control column")
        press(arrow(123), on: remove)
        XCTAssertIdentical(window?.firstResponder, rows[2])
        press(arrow(126), on: rows[2])
        XCTAssertIdentical(window?.firstResponder, rows[1])
    }

    func test_arrowColumn_followsTheStopYouLeave_andAddHostUsesTheRowColumn() throws {
        try seed(ssh: "Host devbox\n", config: "ssh-host = devbox\nssh-host = ops@10.0.0.6\n")
        let detail = mount()
        let rows = hostRows(in: detail)
        let remove = removeButtons(in: detail)[0]
        let add = try XCTUnwrap(section?.detailStops().last)

        press(arrow(125), on: toggles(in: detail)[0])
        XCTAssertIdentical(window?.firstResponder, remove, "from a control, down steps through controls")
        press(arrow(125), on: remove)
        XCTAssertIdentical(window?.firstResponder, add)
        press(arrow(126), on: add)
        XCTAssertIdentical(window?.firstResponder, rows[1], "up from Add Host lands on the last row")

        press(key(36), on: remove)
        settle()
        XCTAssertFalse(rows[1].isEditable)
        press(arrow(125), on: remove)
        press(arrow(126), on: add)
        XCTAssertIdentical(window?.firstResponder, remove, "a removed host's only stop is its button")
        press(arrow(126), on: remove)
        XCTAssertIdentical(window?.firstResponder, toggles(in: detail)[0], "up from a button stays in controls")
    }

    private func escape() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }
}
