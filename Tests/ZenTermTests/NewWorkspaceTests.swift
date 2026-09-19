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

    private func pressCmdOptT(in c: WindowController) throws {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { c.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: 0, context: nil, characters: "†", charactersIgnoringModifiers: "t",
                isARepeat: false, keyCode: 17))
        XCTAssertNil(keys.route(event), "⌘⌥T is claimed, not passed to the pane")
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

    func test_cmdOptT_opensAWorkspaceInTheFocusedPanesFolder_andSwitchesToIt() throws {
        inheritingCWD()
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        spawned.forEach { $0.currentDirectory = root }

        try pressCmdOptT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2"])
        XCTAssertNotEqual(c.activeWorkspaceIDForTesting, first)
        XCTAssertEqual(c.tabOrderForTesting.count, 1)
        XCTAssertEqual(try launchedFolder(of: c)?.standardizedFileURL, root.standardizedFileURL)
    }

    func test_cmdOptT_startsInTheHomeFolder_whenNewTabsDo() throws {
        let c = makeWindow()
        spawned.forEach { $0.currentDirectory = root }

        try pressCmdOptT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2"])
        XCTAssertEqual(try launchedFolder(of: c), ShellLaunch.defaultCWD)
    }

    func test_cmdOptT_takesTheLowestNumberNoOpenWorkspaceHolds() throws {
        let c = makeWindow()
        try pressCmdOptT(in: c)
        try pressCmdOptT(in: c)
        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2", "Workspace 3"])

        c.requestCloseWorkspace(id: c.workspaceIDsForTesting[1])
        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 3"])

        try pressCmdOptT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 3", "Workspace 2"])
    }

    func test_closingTheFirstWorkspace_thenCmdOptT_givesAWorkspaceBack() throws {
        let c = makeWindow()
        c.openWorkspaceForTesting(
            Workspace(title: "Alpha", path: root, main: nil, right: nil, bottom: nil, focus: .main, env: [:]))
        c.handle(.selectWorkspace(1))
        c.handle(.closeWorkspace)
        XCTAssertEqual(c.workspaceNamesForTesting, ["Alpha"])

        try pressCmdOptT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Alpha", "Workspace 1"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting.last)
    }

    func test_twoWorkspacesInOneFolder_areBothKept_andNeitherOpensItsConfiguredEntry() throws {
        inheritingCWD()
        try seedWorkspaces("[Alpha]\npath = \(root.path)\n")
        let c = makeWindow()
        spawned.forEach { $0.currentDirectory = root }
        try pressCmdOptT(in: c)
        spawned.forEach { $0.currentDirectory = root }
        try pressCmdOptT(in: c)
        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2", "Workspace 3"])

        let picker = try openPicker(in: c)
        let alpha = try XCTUnwrap(
            picker.rowViews.compactMap { $0 as? RepoPickerOverlay.RowView }.first { $0.worktree == nil })
        XCTAssertFalse(
            descendants(of: alpha).contains { ($0 as? NSTextField)?.stringValue == "open" },
            "a workspace without a config entry never counts as the configured one being open")
    }

    func test_cmdOptT_withThePickerOpen_opensAWorkspace_andClosesThePicker() throws {
        let c = makeWindow()
        _ = try openPicker(in: c)

        try pressCmdOptT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Workspace 2"])
        XCTAssertNil(pickerIn(c), "the picker closes")
    }
}
