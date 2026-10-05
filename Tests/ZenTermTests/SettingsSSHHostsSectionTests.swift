import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SettingsSSHHostsSectionTests: WindowTestCase {
    private var configRoot: URL!
    private var sshConfig: URL!
    private var window: NSWindow?
    private var section: SettingsSSHHostsSection?
    private let center = SSHHostStatusCenter()

    override func setUpWithError() throws {
        try super.setUpWithError()
        configRoot = try makeTempDir()
        sshConfig = try makeTempDir().appendingPathComponent("config")
        ConfigLoader.defaultRootOverrideForTesting = configRoot
        SSHConfigFiles.userConfigOverrideForTesting = sshConfig
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        window = nil
        section = nil
        SSHConfigFiles.userConfigOverrideForTesting = nil
        ConfigReset.toBuiltIn()
        try super.tearDownWithError()
    }

    private func seed(ssh: String? = nil, config: String?) throws {
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

    private func rows(in view: NSView) -> [SSHHostRow] {
        descendants(of: view).compactMap { $0 as? SSHHostRow }
    }

    private func captions(in view: NSView) -> [String] {
        rows(in: view).compactMap { row in
            descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 13 }?.stringValue
        }
    }

    private func buttons(in row: NSView) -> [AppButton] {
        descendants(of: row).compactMap { $0 as? AppButton }
    }

    private func groupCaptions(in view: NSView) -> [String] {
        view.subviews.flatMap { child -> [String] in
            if child is SSHHostRow { return [] }
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

    private func rowCaption(_ row: SSHHostRow) -> NSTextField? {
        descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 13 }
    }

    @discardableResult
    private func mount(width: CGFloat = 620) -> NSView {
        let section = SettingsSSHHostsSection()
        self.section = section
        section.statusCenter = center
        let detail = section.makeDetailView()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(detail)
        detail.frame = win.contentView!.bounds
        window = win
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

    func test_listsOnlyAddedHosts_evenWhenTheSSHConfigListsOthers() throws {
        try seed(ssh: "Host devbox\nHost prod\n", config: "ssh-host = deploy@10.0.0.5\n")

        let detail = mount()

        XCTAssertEqual(groupCaptions(in: detail), ["SSH HOSTS"])
        XCTAssertEqual(captions(in: detail), ["deploy@10.0.0.5"])
        XCTAssertEqual(rows(in: detail).count, 1)
        XCTAssertNil(emptyHint(in: detail))
    }

    func test_aNamedHost_isListedByName_overItsAddress() throws {
        try seed(config: "ssh-host = devbox: Build box\nssh-host = deploy@10.0.0.5: Deploy\n")

        let detail = mount()

        XCTAssertEqual(captions(in: detail), ["Build box", "Deploy"])
        XCTAssertNotNil(label("devbox", in: detail))
        XCTAssertNotNil(label("deploy@10.0.0.5", in: detail))
        XCTAssertEqual(rows(in: detail).last?.accessibilityLabel(), "Edit Deploy")
    }

    func test_noHostsAnywhere_showsTheEmptyHint() {
        let detail = mount()

        XCTAssertNotNil(emptyHint(in: detail))
        XCTAssertTrue(rows(in: detail).isEmpty)
        XCTAssertEqual(groupCaptions(in: detail), ["SSH HOSTS"])
    }

    func test_aHandEditWhileOpen_addsNewHostsAndDropsDeletedOnes() throws {
        try seed(config: "ssh-host = alpha\nssh-host = beta\n")
        let detail = mount()

        try seed(config: "ssh-host = beta\nssh-host = gamma\n")

        waitUntil(captions(in: detail) == ["beta", "gamma"], "the rows to follow the config")
    }

    func test_aResolvedDestination_showsUnderTheHost() throws {
        try seed(config: "ssh-host = devbox\nssh-host = prod\n")
        center.setDestination("drew@10.0.0.2", host: SSHHostID(alias: "devbox"))

        let detail = mount()
        waitUntil(
            descendants(of: detail).contains { ($0 as? NSTextField)?.stringValue == "drew@10.0.0.2" },
            "the resolved destination to show")

        XCTAssertEqual(captions(in: detail), ["devbox", "prod"])
    }

    func test_aNamedHost_describesItselfByAlias_thenItsAddressWhenTheyDiffer() throws {
        for (host, destination) in ["devbox": "drew@10.0.0.2", "prod": "prod", "ops": "drew@10.0.0.3"] {
            center.setDestination(destination, host: SSHHostID(alias: host))
        }
        try seed(
            config: "ssh-host = devbox: Build box\nssh-host = prod: Production\nssh-host = ops\n")

        let detail = mount()
        waitUntil(label("drew@10.0.0.3", in: detail) != nil, "the resolved destinations to show")

        XCTAssertEqual(captions(in: detail), ["Build box", "Production", "ops"])
        XCTAssertNotNil(label("devbox · drew@10.0.0.2", in: detail))
        XCTAssertNotNil(label("prod", in: detail), "an address that is the alias is not repeated")
    }

    func test_aHostTheProbeHasNotReached_showsNoAddressUntilItDoes() throws {
        try seed(config: "ssh-host = devbox\n")
        let detail = mount()
        XCTAssertEqual(rows(in: detail).count, 1)
        XCTAssertNil(label("drew@10.0.0.2", in: detail))

        center.setDestination("drew@10.0.0.2", host: SSHHostID(alias: "devbox"))

        waitUntil(label("drew@10.0.0.2", in: detail) != nil, "the address to appear")
    }

    func test_anAddressTheProbeDropsOrChanges_followsLive() throws {
        try seed(config: "ssh-host = devbox\n")
        let detail = mount()
        center.setDestination("drew@10.0.0.2", host: SSHHostID(alias: "devbox"))
        waitUntil(label("drew@10.0.0.2", in: detail) != nil, "the address to appear")

        center.setDestination("drew@10.0.0.9", host: SSHHostID(alias: "devbox"))

        waitUntil(label("drew@10.0.0.9", in: detail) != nil, "the new address to appear")
        XCTAssertNil(label("drew@10.0.0.2", in: detail))
    }

    func test_aStatusChangeThatMovesNoAddress_doesNotRebuildTheRows() throws {
        try seed(config: "ssh-host = devbox\n")
        let detail = mount()
        let row = try XCTUnwrap(rows(in: detail).first)

        center.setReachable(true, host: SSHHostID(alias: "devbox"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertIdentical(rows(in: detail).first, row)
    }

    func test_aRow_showsItsStatusWordInTheStatusInk_andFollowsChangesLive() throws {
        try seed(config: "ssh-host = devbox\nssh-host = prod\n")
        let detail = mount()
        let devbox = SSHHostID(alias: "devbox")
        let row = try XCTUnwrap(rows(in: detail).first)

        XCTAssertEqual(row.renderedStatusForTesting.word, "Offline")
        XCTAssertEqual(row.renderedStatusForTesting.ink, SSHHostStatus.offline.ink)

        center.setReachable(true, host: devbox)
        waitUntil(row.renderedStatusForTesting.word == "Online", "the row to read Online")
        XCTAssertEqual(row.renderedStatusForTesting.ink, SSHHostStatus.online.ink)

        center.setConnected(true, host: devbox)
        waitUntil(row.renderedStatusForTesting.word == "Connected", "the row to read Connected")
        XCTAssertEqual(row.renderedStatusForTesting.ink, SSHHostStatus.connected.ink)
        XCTAssertEqual(row.accessibilityValue() as? String, "Connected")
        XCTAssertEqual(rows(in: detail)[1].renderedStatusForTesting.word, "Offline", "only that host moved")
        XCTAssertIdentical(rows(in: detail).first, row, "the row is updated in place")
    }

    func test_aLongNameAndAddress_truncate_andLeaveTheStatusWordWholeInsideTheRow() throws {
        let longName = String(repeating: "a very long host name ", count: 8)
        let longAddress = "someone@" + String(repeating: "deeply.nested.", count: 12) + "example.com"
        try seed(config: "ssh-host = devbox: \(longName)\n")
        center.setDestination(longAddress, host: SSHHostID(alias: "devbox"))
        center.setConnected(true, host: SSHHostID(alias: "devbox"))
        let detail = mount(width: 260)
        detail.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(rows(in: detail).first)
        row.layoutSubtreeIfNeeded()

        let status = row.statusFrameInRowForTesting
        XCTAssertEqual(row.renderedStatusForTesting.word, "Connected")
        XCTAssertTrue(row.bounds.contains(status), "status \(status) inside row \(row.bounds)")
        let wordWidth = ("Connected" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        XCTAssertGreaterThanOrEqual(status.width, wordWidth, "the word is not squeezed")
        let labels = descendants(of: row).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.allSatisfy { $0.frame.maxX <= row.bounds.maxX }, "no label spills out of the row")
        let hostLabels = labels.filter { $0.stringValue != "Connected" }
        XCTAssertEqual(hostLabels.count, 2)
        for label in hostLabels {
            XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
            XCTAssertLessThan(label.contentCompressionResistancePriority(for: .horizontal).rawValue, 500)
        }
        let word = try XCTUnwrap(labels.first { $0.stringValue == "Connected" })
        XCTAssertEqual(word.contentCompressionResistancePriority(for: .horizontal), .required)
    }

    func test_aHandEditedName_refreshesTheOpenRow() throws {
        try seed(config: "ssh-host = devbox: Build box\n")
        let detail = mount()

        try seed(config: "ssh-host = devbox: Builder\n")

        waitUntil(captions(in: detail) == ["Builder"], "the row to follow the new name")
        XCTAssertEqual(rows(in: detail).first?.accessibilityLabel(), "Edit Builder")
        XCTAssertNotNil(label("devbox", in: detail))
    }

    func test_aRow_carriesNoButton() throws {
        try seed(config: "ssh-host = devbox\nssh-host = prod\n")
        let detail = mount()

        XCTAssertTrue(rows(in: detail).allSatisfy { buttons(in: $0).isEmpty })
    }

    func test_editingAHost_passesTheCentersAddress() throws {
        try seed(config: "ssh-host = devbox\n")
        center.setDestination("drew@10.0.0.2", host: SSHHostID(alias: "devbox"))
        let detail = mount()
        var edited: String?
        section?.onEditHost = { _, address in edited = address }
        let row = try XCTUnwrap(descendants(of: detail).compactMap { $0 as? SSHHostRow }.first)

        row.onActivate?()

        XCTAssertEqual(edited, "drew@10.0.0.2")
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
        config: String?, _ body: (WindowController, NSView) throws -> Void
    ) throws {
        let originalSurface = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { true }
        try seed(config: config)
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        defer {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            TerminalSurfaceFactory.makeOverride = originalSurface
        }
        c.mountAndStart()
        let content = try XCTUnwrap(c.window.contentView)
        c.openSettings(for: .setting(key: "ssh-host"))
        waitUntil(emptyHint(in: content) != nil || !captions(in: content).isEmpty, "Settings to land on SSH Hosts")
        content.layoutSubtreeIfNeeded()
        try body(c, content)
    }

    private func addHostThroughSettings(
        _ host: String, name: String? = nil, check: (WindowController, NSView) throws -> Void
    ) throws {
        try inSettings(config: nil) { c, content in
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
        try addHostThroughSettings("deploy@10.0.0.5") { c, content in
            XCTAssertTrue(configText().contains("ssh-host = deploy@10.0.0.5"), "got: \(configText())")
            waitUntil(
                captions(in: content) == ["deploy@10.0.0.5"], "Settings to reopen listing the new host")
            settle()
            XCTAssertIdentical(c.window.firstResponder, rows(in: content)[0], "focus lands on the host just added")
            waitUntil(
                c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting) == ["deploy@10.0.0.5"],
                "the sidebar to list the new host")
        }
    }

    func test_addingAHostWithAName_writesTheName_andListsItByName() throws {
        try addHostThroughSettings("deploy@10.0.0.5", name: "Deploy box") { c, content in
            XCTAssertTrue(configText().contains("ssh-host = deploy@10.0.0.5: Deploy box\n"), "got: \(configText())")
            waitUntil(captions(in: content) == ["Deploy box"], "Settings to reopen listing the host by name")
            waitUntil(
                c.sidebarForTesting.view.hostRowsForTesting.map(\.titleForTesting) == ["Deploy box"],
                "the sidebar to list the host by name")
        }
    }

    func test_aClickOnAHostRow_opensItsEditForm() throws {
        try inSettings(config: "ssh-host = devbox: Build box\nssh-host = deploy@10.0.0.5\n") {
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
        try inSettings(config: "ssh-host = deploy@10.0.0.5: Deploy box\n") { _, content in
            let row = try XCTUnwrap(rows(in: content).first)

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

    func test_savingAHostThatIsGone_keepsTheFormOpen_andShowsTheErrorInIt() throws {
        try inSettings(config: "ssh-host = ops@10.0.0.6\n") { c, content in
            let row = rows(in: content)[0]
            press(key(36), on: row)
            try seed(config: "")

            try saveEdit(typing: "Ops", in: c, content)

            let overlay = try XCTUnwrap(form(in: content))
            let texts = descendants(of: overlay).compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(texts.contains { $0.contains("it's no longer in the host list") }, "\(texts)")
        }
    }

    private func saveEdit(
        ofRow index: Int? = nil, typing name: String, in c: WindowController, _ content: NSView
    ) throws {
        if let index { press(key(36), on: rows(in: content)[index]) }
        let overlay = try XCTUnwrap(form(in: content))
        descendants(of: overlay).compactMap { $0 as? FieldBox }[1].setText(name)
        let save = try XCTUnwrap(
            descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Save" })
        c.window.makeFirstResponder(save)
        save.keyDown(with: key(36))
    }

    func test_saveWritesTheName_andClearingItRemovesTheName() throws {
        try inSettings(config: "ssh-host = devbox  # the build box\n") { c, content in
            for (typed, line) in [
                ("Builder", "ssh-host = devbox: Builder  # the build box\n"),
                ("", "ssh-host = devbox  # the build box\n"),
            ] {
                let row = try XCTUnwrap(rows(in: content).first)
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
                XCTAssertIdentical(c.window.firstResponder, rows(in: content).first, "focus is back on the host")
            }
        }
    }

    func test_keyboard_returnOpensTheForm_andRightReachesNoControl() throws {
        try seed(config: "ssh-host = devbox: Build box\nssh-host = ops@10.0.0.6\n")
        let detail = mount()
        var edited: [SSHHostEntry] = []
        section?.onEditHost = { host, _ in edited.append(host) }
        let rows = rows(in: detail)
        let add = try XCTUnwrap(section?.detailStops().last)

        XCTAssertEqual(
            section?.detailStops().map(ObjectIdentifier.init), [rows[0], rows[1], add].map(ObjectIdentifier.init))

        press(key(36), on: rows[0])
        XCTAssertEqual(edited, [SSHHostEntry(alias: "devbox", name: "Build box")])

        XCTAssertNil(rows[0].onArrowRight, "there is no control for → to reach")
    }

    func test_arrows_moveBetweenRowsOnly_andAddHostIsTheLastStop() throws {
        try seed(config: "ssh-host = devbox\nssh-host = ops@10.0.0.6\n")
        let detail = mount()
        let rows = rows(in: detail)
        let add = try XCTUnwrap(section?.detailStops().last)

        press(arrow(125), on: rows[0])
        XCTAssertIdentical(window?.firstResponder, rows[1])
        press(arrow(125), on: rows[1])
        XCTAssertIdentical(window?.firstResponder, add)
        press(arrow(126), on: add)
        XCTAssertIdentical(window?.firstResponder, rows[1])
        press(arrow(126), on: rows[1])
        XCTAssertIdentical(window?.firstResponder, rows[0])
    }

    func test_removingFromTheForm_returnsToTheListWithoutTheHost_andFocusOnItsNeighbour() throws {
        try inSettings(config: "ssh-host = alpha\nssh-host = beta\nssh-host = gamma\n") { c, content in
            press(key(36), on: rows(in: content)[1])
            let overlay = try XCTUnwrap(form(in: content))
            let remove = try XCTUnwrap(
                descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Remove" })

            remove.onTap()
            waitUntil(form(in: content) == nil && rows(in: content).count == 2, "Settings to come back")
            settle()

            XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["alpha", "gamma"])
            XCTAssertFalse(configText().contains("beta"))
            XCTAssertIdentical(c.window.firstResponder, rows(in: content)[1], "focus lands on the next host")
        }
    }

    func test_aFailedRemove_staysInTheForm_withTheErrorAndFocusOnRemove() throws {
        try inSettings(config: "ssh-host = alpha\n") { c, content in
            press(key(36), on: rows(in: content)[0])
            let overlay = try XCTUnwrap(form(in: content))
            let remove = try XCTUnwrap(
                descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Remove" })
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: configRoot.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configRoot.path)
            }

            remove.onTap()

            XCTAssertNotNil(form(in: content))
            XCTAssertEqual(GeneralConfig.current.sshHostAliases, ["alpha"])
            let texts = descendants(of: overlay).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
            XCTAssertTrue(
                texts.contains { $0.stringValue.hasPrefix("Couldn't remove alpha from ZenTerm's config: ") },
                "\(texts.map(\.stringValue))")
            XCTAssertIdentical(c.window.firstResponder, remove)
        }
    }

    private func escape() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }
}
