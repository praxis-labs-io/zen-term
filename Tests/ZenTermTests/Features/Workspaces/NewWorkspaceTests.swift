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

        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName, PathDisplay.homeName])
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

    func test_cmdCtrlT_workspacesAtOneFolder_shareItsName() throws {
        let c = makeWindow()
        try pressCmdCtrlT(in: c)
        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName, PathDisplay.homeName, PathDisplay.homeName])
        XCTAssertEqual(Set(c.workspaceIDsForTesting).count, 3, "a shared name never merges them")

        c.requestCloseWorkspace(id: c.workspaceIDsForTesting[1])
        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName, PathDisplay.homeName, PathDisplay.homeName])
    }

    func test_closingTheFirstWorkspace_thenCmdCtrlT_givesAWorkspaceBack() throws {
        let c = makeWindow()
        c.openWorkspaceForTesting(
            Workspace(title: "Alpha", path: root, tabs: [], env: [:]))
        c.handle(.selectWorkspace(1))
        c.handle(.closeWorkspace)
        XCTAssertEqual(c.workspaceNamesForTesting, ["Alpha"])

        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Alpha", PathDisplay.homeName])
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
        let rootName = try XCTUnwrap(PathDisplay.folderName(root))
        XCTAssertEqual(c.workspaceNamesForTesting, [rootName, rootName, PathDisplay.homeName])

        let picker = try openPicker(in: c)
        let alpha = try XCTUnwrap(
            picker.rowViews.compactMap { $0 as? RepoPickerOverlay.RowView }.first { $0.worktree == nil })
        XCTAssertFalse(
            descendants(of: alpha).contains { ($0 as? NSTextField)?.stringValue == "open" },
            "a workspace without a config entry never counts as the configured one being open")
    }

    func test_anEmptyQuery_listsNoNewWorkspaceRow_andTheFieldShowsTheChord() throws {
        let c = makeWindow()
        let picker = try openPicker(in: c)
        c.window.layoutIfNeeded()

        XCTAssertNil(newWorkspaceRowIfListed(of: picker))
        let tip = try XCTUnwrap(picker.newTipForTesting, "the field's trailing slot names the chord")
        XCTAssertTrue(tip.isDescendant(of: picker.card))
        XCTAssertEqual(descendants(of: tip).compactMap { ($0 as? KeycapView)?.shortcut }, ["⌘⌃T"])
        XCTAssertEqual(descendants(of: tip).compactMap { ($0 as? NSTextField)?.stringValue }.first, "New")
    }

    func test_cmdCtrlT_withThePickerOpen_opensAWorkspace_andClosesThePicker() throws {
        let c = makeWindow()
        _ = try openPicker(in: c)

        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName, PathDisplay.homeName])
        XCTAssertNil(pickerIn(c), "the picker closes")
    }

    private func searchField(of picker: RepoPickerOverlay) throws -> NSTextField {
        try XCTUnwrap(
            descendants(of: picker).compactMap { $0 as? NSTextField }
                .first { ($0.delegate as? PaletteOverlay) === picker })
    }

    // Through the field editor, so the query arrives by the text-change notification a keystroke sends.
    private func type(_ text: String, into picker: RepoPickerOverlay, in c: WindowController) throws {
        let field = try searchField(of: picker)
        XCTAssertTrue(c.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func command(_ selector: Selector, in picker: RepoPickerOverlay) throws {
        _ = picker.control(try searchField(of: picker), textView: NSTextView(), doCommandBy: selector)
    }

    private func newWorkspaceRow(of picker: RepoPickerOverlay) throws -> RepoPickerOverlay.ActionRowView {
        try XCTUnwrap(picker.rowViews.first as? RepoPickerOverlay.ActionRowView)
    }

    private func newWorkspaceRowIfListed(of picker: RepoPickerOverlay) -> RepoPickerOverlay.ActionRowView? {
        picker.rowViews.compactMap { $0 as? RepoPickerOverlay.ActionRowView }
            .first { $0.title.hasPrefix("New Workspace") }
    }

    func test_aQueryThatMatchesNothing_namesTheNewWorkspace_trimmed() throws {
        let c = makeWindow()
        let picker = try openPicker(in: c)

        try type("  api server ", into: picker, in: c)
        XCTAssertEqual(try newWorkspaceRow(of: picker).title, "New Workspace “api server”")
        try command(#selector(NSResponder.insertNewline(_:)), in: picker)

        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName, "api server"])
        XCTAssertEqual(c.window.title, "api server")
        XCTAssertNil(pickerIn(c), "the picker closes")
    }

    func test_theRow_followsTheQuery_andLeavesWithIt_handingTheSlotBackTheChord() throws {
        let c = makeWindow()
        let picker = try openPicker(in: c)

        try type("api", into: picker, in: c)
        XCTAssertEqual(try newWorkspaceRow(of: picker).title, "New Workspace “api”")
        XCTAssertNil(picker.newTipForTesting, "the row names the chord while it is listed")

        try type("", into: picker, in: c)

        XCTAssertNil(newWorkspaceRowIfListed(of: picker))
        XCTAssertNotNil(picker.newTipForTesting)
        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName], "nothing was made")
    }

    func test_arrowingToNewWorkspacePastAMatch_stillNamesItTheQuery() throws {
        try seedWorkspaces("[Alpha]\npath = ~/Dev/alpha\n")
        let c = makeWindow()
        let picker = try openPicker(in: c)
        try type("Al", into: picker, in: c)
        XCTAssertNotEqual(picker.selected, 0, "the match takes the selection")

        try command(#selector(NSResponder.moveUp(_:)), in: picker)
        XCTAssertEqual(picker.selected, 0)
        try command(#selector(NSResponder.insertNewline(_:)), in: picker)

        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName, "Al"])
    }

    func test_cmdCtrlT_withAQueryInThePicker_namesTheWorkspaceTheQuery() throws {
        let c = makeWindow()
        let picker = try openPicker(in: c)
        try type("scratch", into: picker, in: c)

        try pressCmdCtrlT(in: c)

        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName, "scratch"])
    }
}
