import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SidebarWorktreeRowTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var tempRoot: URL!

    private let alpha = URL(fileURLWithPath: NSString("~/Dev/alpha").expandingTildeInPath, isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-sidebar-worktrees-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        try """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        """.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func openPicker(in c: WindowController) throws -> RepoPickerOverlay {
        c.handle(.toggleRepoPicker)
        waitUntil(pickers(in: c).first != nil, "the picker to be presented")
        return try XCTUnwrap(pickers(in: c).first)
    }

    private func pickers(in c: WindowController) -> [RepoPickerOverlay] {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }
    }

    private func searchField(of picker: RepoPickerOverlay) throws -> NSTextField {
        try XCTUnwrap(
            descendants(of: picker).compactMap { $0 as? NSTextField }
                .first { ($0.delegate as? PaletteOverlay) === picker })
    }

    private func choose(row index: Int, in picker: RepoPickerOverlay) throws {
        let field = try searchField(of: picker)
        for _ in 0..<index {
            _ = picker.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        }
        _ = picker.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func openWorkspace(atConfigIndex row: Int, in c: WindowController) throws {
        try choose(row: row, in: try openPicker(in: c))
    }

    private func openAlphaWorktree(branch: String?, head: String = "a41c9e2d0f", in c: WindowController) throws {
        let picker = try openPicker(in: c)
        let worktree = Worktree(
            path: alpha.appendingPathComponent(branch ?? head, isDirectory: true), branch: branch, head: head,
            isLocked: false)
        picker.setWorktrees(
            WorktreeListing(commonDir: alpha.appendingPathComponent(".git"), worktrees: [worktree]), for: alpha)
        try choose(row: 1, in: picker)
    }

    private func rows(of c: WindowController) -> [SettingsNavRow] { c.sidebarForTesting.view.rowsForTesting }

    private func titles(of c: WindowController) -> [String] { rows(of: c).map(\.titleForTesting) }

    private func click(_ row: SettingsNavRow) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        row.mouseDown(with: event)
    }

    private func press(_ key: String, typing characters: String, keyCode: UInt16, in c: WindowController) throws {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { c.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: keyCode))
        XCTAssertNil(keys.route(event), "the chord is claimed, not passed to the pane")
    }

    func test_aWorktreeOpenedFromThePicker_withItsWorkspaceClosed_nestsUnderAGhostRow() throws {
        let c = makeWindow()

        try openAlphaWorktree(branch: "feature/one", in: c)

        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "feature/one"])
        let ghost = rows(of: c)[1]
        XCTAssertEqual(ghost.variant, .faint)
        XCTAssertEqual(ghost.titleInkForTesting, Theme.current.chrome.ink(.faint))
        XCTAssertEqual(ghost.detailForTesting, "")
        XCTAssertNil(ghost.tooltip, "a ghost takes no ⌘⌥ number")
        XCTAssertEqual(rows(of: c)[2].variant, .nested(symbol: "arrow.triangle.branch"))
        XCTAssertEqual(rows(of: c)[2].layer?.backgroundColor, Theme.current.chrome.fill(.rest).cgColor)
    }

    func test_clickingTheGhost_opensItsWorkspaceInThatPlace() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)

        try click(rows(of: c)[1])

        XCTAssertEqual(c.workspaceNamesForTesting, ["Home", "Alpha: feature/one", "Alpha"])
        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "feature/one"])
        XCTAssertEqual(rows(of: c).map(\.variant), [.standard, .standard, .nested(symbol: "arrow.triangle.branch")])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting[2])
    }

    func test_closingTheLastWorktree_takesItsGhostWithIt() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)
        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "feature/one"])

        c.handle(.closeTab)

        XCTAssertEqual(titles(of: c), ["Home"])
    }

    func test_aWorktreeOpenedLast_nestsUnderItsOpenWorkspace() throws {
        let c = makeWindow()
        try openWorkspace(atConfigIndex: 0, in: c)
        try openWorkspace(atConfigIndex: 1, in: c)

        try openAlphaWorktree(branch: "feature/one", in: c)

        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "feature/one", "Beta"])
    }

    func test_aDetachedWorktree_isNamedByItsShortHash() throws {
        let c = makeWindow()

        try openAlphaWorktree(branch: nil, in: c)

        XCTAssertEqual(titles(of: c).last, "a41c9e2")
    }

    func test_cmdOptDigits_followTheSidebar_nestedWorktreesIncluded() throws {
        let c = makeWindow()
        try openWorkspace(atConfigIndex: 0, in: c)
        try openWorkspace(atConfigIndex: 1, in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        let worktree = c.activeWorkspaceIDForTesting
        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "feature/one", "Beta"])

        try press("1", typing: "¡", keyCode: 18, in: c)
        try press("3", typing: "£", keyCode: 20, in: c)

        XCTAssertEqual(c.activeWorkspaceIDForTesting, worktree)
    }

    func test_rowTooltips_numberTheSidebar_skippingTheGhost() throws {
        let c = makeWindow()
        try openWorkspace(atConfigIndex: 1, in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        XCTAssertEqual(titles(of: c), ["Home", "Beta", "Alpha", "feature/one"])

        let shortcuts = rows(of: c).map { $0.tooltip?.shortcutForTesting }

        XCTAssertEqual(shortcuts, ["⌘⌥1", "⌘⌥2", nil, "⌘⌥3"])
    }

    func test_cmdOptBrackets_stepThroughTheSidebar_nestedWorktreesIncluded() throws {
        let c = makeWindow()
        try openWorkspace(atConfigIndex: 0, in: c)
        try openWorkspace(atConfigIndex: 1, in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        let ids = c.workspaceIDsForTesting
        c.activateWorkspaceForTesting(ids[1])

        try press("]", typing: "‘", keyCode: 30, in: c)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, ids[3], "Alpha's worktree follows Alpha")

        try press("]", typing: "‘", keyCode: 30, in: c)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, ids[2], "Beta follows the worktree")
    }

    private var menu: SidebarRowMenu { controller!.sidebarForTesting.view.rowMenu }

    private func rightClick(_ row: SettingsNavRow) throws {
        row.rightMouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1)))
    }

    func test_aWorktreeRowsMenu_offersOnlyClose_andAGhostHasNone() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)

        try rightClick(rows(of: c)[2])
        XCTAssertEqual(menu.itemViewsForTesting.map(\.title), ["Close Workspace"])

        try rightClick(rows(of: c)[1])
        XCTAssertFalse(menu.isOpen)
    }

    func test_closeFromTheMenu_closesThatWorkspace_evenInTheBackground() throws {
        let c = makeWindow()
        try openWorkspace(atConfigIndex: 0, in: c)
        try openWorkspace(atConfigIndex: 1, in: c)
        let beta = c.activeWorkspaceIDForTesting

        try rightClick(rows(of: c)[1])
        try XCTUnwrap(menu.itemViewsForTesting.last).mouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))

        XCTAssertEqual(titles(of: c), ["Home", "Beta"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, beta, "closing a background workspace leaves the screen alone")
        XCTAssertFalse(menu.isOpen)
    }

    func test_closingAWorkspace_landsOnItsNeighbourInTheSidebar_andLeavesItsWorktreeUnderAGhost() throws {
        let c = makeWindow()
        try openWorkspace(atConfigIndex: 0, in: c)
        try openWorkspace(atConfigIndex: 1, in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        let worktree = c.activeWorkspaceIDForTesting
        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[1])
        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "feature/one", "Beta"])

        c.handle(.closeWorkspace)

        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "feature/one", "Beta"])
        XCTAssertEqual(rows(of: c)[1].variant, .faint, "Alpha's row turns ghost")
        XCTAssertEqual(c.activeWorkspaceIDForTesting, worktree, "the next row down, not the next one opened")
    }

    func test_aParentOpenedIntoItsGhostsPlace_staysThere_afterItsWorktreeCloses() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)
        try openWorkspace(atConfigIndex: 1, in: c)
        try click(rows(of: c)[1])
        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "feature/one", "Beta"])

        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[1])
        c.handle(.closeTab)

        XCTAssertEqual(titles(of: c), ["Home", "Alpha", "Beta"])
    }
}
