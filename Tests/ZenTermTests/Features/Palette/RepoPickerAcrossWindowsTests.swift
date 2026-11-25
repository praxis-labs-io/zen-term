import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class RepoPickerAcrossWindowsTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var first: WindowController?
    private var second: WindowController?
    private var tempRoot: URL!

    private var startFolderName: String { PathDisplay.folderName(FileManager.default.temporaryDirectory) ?? "" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-across-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        first?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        second?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        first = nil
        second = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private let twoWorkspaces = """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        """

    private func seedWorkspaces(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    // Wired the way `AppDelegate.newWindow` wires them, minus the ordering a test must not do.
    private func makeWindows() -> (WindowController, WindowController) {
        func make() -> WindowController {
            let c = WindowController(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                initialCWD: FileManager.default.temporaryDirectory)
            c.mountAndStart()
            return c
        }
        let one = make()
        let two = make()
        first = one
        second = two
        for window in [one, two] {
            let others = { [weak one, weak two] in [one, two].compactMap { $0 } }
            window.isWorkspaceOpenInAnotherWindow = { [weak window] path in
                AppDelegate.window(holding: path, among: others(), asking: window) != nil
            }
            window.openWorkspacesElsewhere = { [weak window] in
                others().filter { $0 !== window }.flatMap { $0.runningWorkspaces() }
            }
            window.revealWorkspaceElsewhere = { [weak window] id, workspace in
                guard
                    let other = others().first(where: { $0 !== window && $0.windowID == id }),
                    other.holdsWorkspace(workspace)
                else { return false }
                other.window.makeKeyAndOrderFront(nil)
                other.activateWorkspace(workspace)
                return true
            }
            window.onOpenWorkspacesChanged = { [weak window] in
                others().filter { $0 !== window }.forEach { $0.refreshOpenPicker() }
            }
            window.revealWorkspaceInAnotherWindow = { [weak window] path in
                guard let other = AppDelegate.window(holding: path, among: others(), asking: window)
                else { return false }
                other.activateWorkspace(at: path)
                return true
            }
        }
        return (one, two)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func pickers(in c: WindowController) -> [RepoPickerOverlay] {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }
    }

    private func openPicker(in c: WindowController) throws -> RepoPickerOverlay {
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        return try XCTUnwrap(pickers(in: c).first)
    }

    private func move(_ selector: Selector, in picker: RepoPickerOverlay) {
        guard
            let field = descendants(of: picker).compactMap({ $0 as? NSTextField })
                .first(where: { ($0.delegate as? PaletteOverlay) === picker })
        else { return XCTFail("the picker has no search field to arrow in") }
        _ = picker.control(field, textView: NSTextView(), doCommandBy: selector)
    }

    private func rowIndex(_ name: String, in picker: RepoPickerOverlay) -> Int? {
        picker.rowViews.firstIndex { view in
            guard let row = view as? RepoPickerOverlay.RowView else { return false }
            if let running = row.running { return running.id != nil && running.name == name }
            if let worktree = row.worktree { return (worktree.branch ?? worktree.head) == name }
            return row.label == name
        }
    }

    // Arrows onto the named row, so a test says which workspace it means rather than counting keystrokes.
    private func selectRow(_ name: String, in picker: RepoPickerOverlay) {
        guard let index = rowIndex(name, in: picker) else {
            return XCTFail("the picker has no row for \(name)")
        }
        for _ in 0..<picker.rowViews.count { move(#selector(NSResponder.moveUp(_:)), in: picker) }
        for _ in 0..<picker.rowViews.count where picker.selected != index {
            move(#selector(NSResponder.moveDown(_:)), in: picker)
        }
        XCTAssertEqual(picker.selected, index, "the arrows never reached \(name)")
    }

    private func openPicker(in c: WindowController, on name: String) throws -> RepoPickerOverlay {
        let picker = try openPicker(in: c)
        selectRow(name, in: picker)
        return picker
    }

    private func state(at index: Int, in picker: RepoPickerOverlay) -> RepoPickerOverlay.State? {
        (picker.rowViews[index] as? RepoPickerOverlay.RowView)?.state
    }

    private func state(of name: String, in picker: RepoPickerOverlay) -> RepoPickerOverlay.State? {
        guard let index = rowIndex(name, in: picker) else { return nil }
        return state(at: index, in: picker)
    }

    private func detailText(of name: String, in picker: RepoPickerOverlay) -> [String] {
        guard let index = rowIndex(name, in: picker) else { return [] }
        return descendants(of: picker.rowViews[index]).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func pressReturn(in picker: RepoPickerOverlay) {
        guard
            let field = descendants(of: picker).compactMap({ $0 as? NSTextField })
                .first(where: { ($0.delegate as? PaletteOverlay) === picker })
        else { return XCTFail("the picker has no search field to press Return in") }
        _ = picker.control(
            field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func hintIsShown(_ label: String, in picker: RepoPickerOverlay) -> Bool {
        guard let bar = descendants(of: picker).compactMap({ $0 as? HintFooter }).first else { return false }
        return descendants(of: bar).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == label && !$0.isHiddenOrHasHiddenAncestor
        }
    }

    func test_returnOnAWorkspaceOpenInAnotherWindow_switchesThere_ratherThanOpeningASecondCopy() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two, on: "Alpha"))
        let alpha = two.activeWorkspaceIDForTesting
        let alphaTab = try XCTUnwrap(two.tabIDsForTesting(workspace: alpha).first)
        let alphaSurface = try XCTUnwrap(two.controllerForTesting(tab: alphaTab)?.allSurfaces.first)
        two.handle(.selectWorkspace(1))
        XCTAssertNotEqual(two.activeWorkspaceIDForTesting, alpha)

        pressReturn(in: try openPicker(in: one, on: "Alpha"))

        XCTAssertEqual(one.workspaceNamesForTesting, [startFolderName], "no second copy in the asking window")
        XCTAssertEqual(two.workspaceNamesForTesting, [startFolderName, "Alpha"], "nor a second in the holder")
        XCTAssertEqual(two.activeWorkspaceIDForTesting, alpha, "the window holding it switches to it")
        XCTAssertTrue(
            two.controllerForTesting(tab: alphaTab)?.allSurfaces.first === alphaSurface,
            "the same shell, so the recipe never ran twice")
        XCTAssertTrue(pickers(in: one).isEmpty, "the picker closes")
    }

    func test_aWorkspaceOpenInAnotherWindow_readsOtherWindow() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two, on: "Alpha"))

        let picker = try openPicker(in: one)
        XCTAssertEqual(state(of: "Alpha", in: picker), .otherWindow)
        XCTAssertTrue(detailText(of: "Alpha", in: picker).contains("Other window"), "the row says so")
    }

    func test_renamingAWorkspace_updatesAnOpenPickerInTheOtherWindow() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two, on: "Alpha"))
        let picker = try openPicker(in: one)
        XCTAssertEqual(state(of: "Alpha", in: picker), .otherWindow)

        XCTAssertTrue(two.renameWorkspace(two.activeWorkspaceIDForTesting, to: "api"))

        XCTAssertEqual(state(of: "api", in: picker), .otherWindow, "the open picker shows the new name")
        XCTAssertNil(
            picker.rowViews.compactMap { $0 as? RepoPickerOverlay.RowView }
                .first { $0.running?.name == "Alpha" }, "and no longer the old one")
    }

    func test_onlyTheActiveWorkspace_readsCurrent_andTheOtherOpenOnesReadOpen() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, _) = makeWindows()
        pressReturn(in: try openPicker(in: one, on: "Alpha"))

        let showingAlpha = try openPicker(in: one)
        XCTAssertEqual(state(of: "Alpha", in: showingAlpha), .current)
        XCTAssertEqual(state(of: startFolderName, in: showingAlpha), .open)
        XCTAssertEqual(
            showingAlpha.rowViews[showingAlpha.selected].accessibilityLabel(), startFolderName,
            "the picker starts on the first open row that is not the one showing")
        pressReturn(in: showingAlpha)
        waitUntil(pickers(in: one).isEmpty, "Return on an open row to switch and close the picker")

        let showingStart = try openPicker(in: one)
        XCTAssertEqual(state(of: "Alpha", in: showingStart), .open)
        XCTAssertEqual(state(of: startFolderName, in: showingStart), .current)
    }

    func test_aWorkspaceOpenNowhere_readsNoState() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, _) = makeWindows()
        let picker = try openPicker(in: one)

        XCTAssertNotNil(rowIndex("Alpha", in: picker))
        XCTAssertNil(state(of: "Alpha", in: picker))
    }

    func test_anUnconfiguredWorkspaceOpenElsewhere_readsOtherWindow_andReturnRaisesIt() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        let held = two.activeWorkspaceIDForTesting

        let picker = try openPicker(in: one)
        guard
            let index = picker.rowViews.firstIndex(where: {
                ($0 as? RepoPickerOverlay.RowView)?.running?.window == two.windowID
            })
        else {
            return XCTFail("no row is held by the other window, and both name their first after the same folder")
        }

        XCTAssertEqual(
            state(at: index, in: picker), .otherWindow,
            "the other window's unconfigured workspace has no config entry to be found through")

        picker.activateRow(at: index)

        XCTAssertEqual(one.workspaceNamesForTesting, [startFolderName], "nothing starts in the asking window")
        XCTAssertEqual(two.workspaceNamesForTesting, [startFolderName], "nor in the one holding it")
        XCTAssertEqual(two.activeWorkspaceIDForTesting, held, "the window holding it is raised on it")
        XCTAssertTrue(pickers(in: one).isEmpty, "the picker closes")
    }

    func test_theFooterReadsSwitchOverAWorkspaceOpenInAnotherWindow() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two, on: "Alpha"))

        let picker = try openPicker(in: one, on: "Alpha")

        XCTAssertTrue(hintIsShown("Switch", in: picker), "↵ crosses to the window holding it")
        XCTAssertFalse(hintIsShown("Open", in: picker), "it is not opened a second time")
    }

    func test_aWorkspaceOpenNowhere_stillOpensIntoTheAskingWindow() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()

        pressReturn(in: try openPicker(in: one, on: "Alpha"))

        XCTAssertEqual(one.workspaceNamesForTesting, [startFolderName, "Alpha"])
        XCTAssertEqual(two.workspaceNamesForTesting, [startFolderName])
    }

    func test_aPickerOpenInAnotherWindow_marksTheWorktreeWhenItGoes() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        let parent = try XCTUnwrap(ConfigLoader.loadWorkspacesBlocking().first { $0.title == "Alpha" })
        let worktree = Worktree(
            path: parent.path.appendingPathComponent("feature/one", isDirectory: true), branch: "feature/one",
            head: "a41c9e2d0f", isLocked: false)
        two.openWorkspaceForTesting(
            RepoPickerOverlay.workspace(for: worktree, parent: parent, repoRoot: nil),
            origin: WorktreeOrigin(parent: parent, worktree: worktree))
        let picker = try openPicker(in: one)
        func removedRows() -> Int {
            picker.rowViews.filter { ($0 as? RepoPickerOverlay.RowView)?.running?.removedWorktreeName != nil }.count
        }
        XCTAssertEqual(removedRows(), 0)
        WorktreeStore.isRemovedOverrideForTesting = { _ in true }

        two.checkForRemovedWorktreesForTesting()
        waitUntil(removedRows() == 1, "the other window's picker to mark the row without a reopen")

        WorktreeStore.isRemovedOverrideForTesting = { _ in false }
        two.checkForRemovedWorktreesForTesting()
        waitUntil(removedRows() == 0, "and to clear it again")
    }
}
