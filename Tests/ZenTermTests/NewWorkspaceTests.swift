import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class NewWorkspaceTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        spawned = []
        TerminalSurfaceFactory.makeOverride = { [unowned self] in
            let surface = RecordingSurface()
            spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-new-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = root
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        c.mountAndStart()
        controller = c
        return c
    }

    private func inheritingCWD() {
        var config = GeneralConfig.current
        config.tabInheritCWD = true
        GeneralConfig.setCurrentForTesting(config)
    }

    private func pressCmdCtrlT(in c: WindowController) throws {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { c.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{14}", charactersIgnoringModifiers: "t",
                isARepeat: false, keyCode: 17))
        XCTAssertNil(keys.route(event), "⌘⌃T is claimed, not passed to the pane")
    }

    private func launchedFolder(of c: WindowController) throws -> URL? {
        let tab = try XCTUnwrap(c.activeTabIDForTesting)
        let surface = try XCTUnwrap(c.controllerForTesting(tab: tab)?.allSurfaces.first as? RecordingSurface)
        return surface.lastConfig?.workingDirectory
    }

    private func seedWorkspaces(_ text: String) throws {
        try text.write(to: root.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func openPicker(in c: WindowController) throws -> RepoPickerOverlay {
        c.handle(.toggleRepoPicker)
        waitUntil(pickerIn(c) != nil, "the picker to be presented")
        return try XCTUnwrap(pickerIn(c))
    }

    private func pickerIn(_ c: WindowController) -> RepoPickerOverlay? {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }.first
    }

    func test_cmdCtrlT_opensAWorkspaceAtHome_andSwitchesToIt() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting

        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2"])
        XCTAssertNotEqual(c.activeWorkspaceIDForTesting, first)
        XCTAssertEqual(c.tabOrderForTesting.count, 1)
        XCTAssertEqual(try launchedFolder(of: c), ShellLaunch.defaultCWD)
    }

    func test_cmdCtrlT_staysAtHome_evenWhereANewTabWouldInheritTheFolder() throws {
        inheritingCWD()
        let c = makeWindow()
        spawned.forEach { $0.currentDirectory = root }

        try pressCmdCtrlT(in: c)

        XCTAssertEqual(
            try launchedFolder(of: c), ShellLaunch.defaultCWD,
            "a workspace is a place of its own, so it never inherits the pane's folder")
    }

    func test_cmdCtrlT_takesTheLowestNumberNoOpenWorkspaceHolds() throws {
        let c = makeWindow()
        try pressCmdCtrlT(in: c)
        try pressCmdCtrlT(in: c)
        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2", "Workspace 3"])

        c.requestCloseWorkspace(id: c.workspaceIDsForTesting[1])
        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 3"])

        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 3", "Workspace 2"])
    }

    func test_closingTheFirstWorkspace_thenCmdCtrlT_givesAWorkspaceBack() throws {
        let c = makeWindow()
        c.openWorkspaceForTesting(
            Workspace(title: "Alpha", path: root, main: nil, right: nil, bottom: nil, focus: .main, env: [:]))
        c.handle(.selectWorkspace(1))
        c.handle(.closeWorkspace)
        XCTAssertEqual(c.workspaceNamesForTesting, ["Alpha"])

        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Alpha", "Workspace 1"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting.last)
    }

    func test_twoWorkspacesInOneFolder_areBothKept_andNeitherOpensItsConfiguredEntry() throws {
        inheritingCWD()
        try seedWorkspaces("[Alpha]\npath = \(root.path)\n")
        let c = makeWindow()
        spawned.forEach { $0.currentDirectory = root }
        try pressCmdCtrlT(in: c)
        spawned.forEach { $0.currentDirectory = root }
        try pressCmdCtrlT(in: c)
        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2", "Workspace 3"])

        let picker = try openPicker(in: c)
        let alpha = try XCTUnwrap(
            picker.rowViews.compactMap { $0 as? RepoPickerOverlay.RowView }.first { $0.worktree == nil })
        XCTAssertFalse(
            descendants(of: alpha).contains { ($0 as? NSTextField)?.stringValue == "open" },
            "a workspace without a config entry never counts as the configured one being open")
    }

    func test_thePickersFirstRow_showsCmdCtrlT_andClickingItOpensAWorkspaceAtHome() throws {
        inheritingCWD()
        let c = makeWindow()
        spawned.forEach { $0.currentDirectory = root }
        let picker = try openPicker(in: c)
        c.window.layoutIfNeeded()
        let row = try XCTUnwrap(picker.rowViews.first as? RepoPickerOverlay.ActionRowView)
        XCTAssertEqual(row.title, "New Workspace")
        XCTAssertEqual(descendants(of: row).compactMap { ($0 as? KeycapView)?.shortcut }, ["⌘⌃T"])

        click(row)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting.last)
        XCTAssertEqual(try launchedFolder(of: c), ShellLaunch.defaultCWD)
        XCTAssertNil(pickerIn(c), "the picker closes")
    }

    private func click(_ row: SelectableRowView) {
        let inside = CGPoint(x: row.bounds.midX, y: row.bounds.midY)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: row.convert(inside, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)!
        }
        row.mouseDown(with: event(.leftMouseDown))
        row.mouseUp(with: event(.leftMouseUp))
    }

    func test_cmdCtrlT_withThePickerOpen_opensAWorkspace_andClosesThePicker() throws {
        let c = makeWindow()
        _ = try openPicker(in: c)

        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2"])
        XCTAssertNil(pickerIn(c), "the picker closes")
    }
}
