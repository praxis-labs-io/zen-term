import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SidebarNewWorktreeTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var tempRoot: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-sidebar-new-worktree-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        repo = try GitFixture.makeRepo(at: tempRoot.appendingPathComponent("repo", isDirectory: true))
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        WorktreeStore.rootOverrideForTesting = tempRoot.appendingPathComponent("worktrees", isDirectory: true)
        try "[Repo]\npath = \(repo.path)\n"
            .write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        WorktreeStore.rootOverrideForTesting = nil
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

    private func modals<T: NSView>(_ type: T.Type, in c: WindowController) -> [T] {
        descendants(of: c.window.contentView!).compactMap { $0 as? T }
    }

    private func rows(of c: WindowController) -> [SettingsNavRow] { c.sidebarForTesting.view.rowsForTesting }

    private func openRepoWorkspace(in c: WindowController) throws -> SettingsNavRow {
        let home = c.activeWorkspaceIDForTesting
        c.handle(.toggleRepoPicker)
        waitUntil(!modals(RepoPickerOverlay.self, in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(modals(RepoPickerOverlay.self, in: c).first)
        picker.activate(index: picker.defaultSelectionIndex(), modifiers: [])
        c.activateWorkspaceForTesting(home)
        let row = try XCTUnwrap(rows(of: c).last)
        waitUntil(row.hoverAccessory != nil, "the row to learn its folder is a repo")
        c.window.contentView?.layoutSubtreeIfNeeded()
        return row
    }

    private func crossing(_ type: NSEvent.EventType, over row: NSView) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)!
    }

    private func clickThroughTheWindow(at view: NSView, in c: WindowController) throws {
        let content = try XCTUnwrap(c.window.contentView)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let target = try XCTUnwrap(content.hitTest(point))
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        target.mouseDown(with: event)
    }

    private func newWorktreeCard(in c: WindowController) throws -> NewWorktreeOverlay {
        waitUntil(!modals(NewWorktreeOverlay.self, in: c).isEmpty, "the New Worktree card to be presented")
        return try XCTUnwrap(modals(NewWorktreeOverlay.self, in: c).first)
    }

    func test_hoveringAWorkspaceRow_swapsItsBranchForNewWorktree() throws {
        let c = makeWindow()
        let row = try openRepoWorkspace(in: c)
        let plus = try XCTUnwrap(row.hoverAccessory)
        XCTAssertTrue(plus.isHidden)
        XCTAssertEqual(row.detailForTesting, "main")

        row.mouseEntered(with: crossing(.mouseEntered, over: row))

        XCTAssertFalse(plus.isHidden)
        XCTAssertTrue(descendants(of: row).contains { $0 is NSTextField && $0.isHidden }, "the branch gives way")

        row.mouseExited(with: crossing(.mouseExited, over: row))

        XCTAssertTrue(plus.isHidden)
        XCTAssertFalse(descendants(of: row).contains { $0 is NSTextField && $0.isHidden })
    }

    func test_clickingThePlus_opensTheNewWorktreeCard_andDoesNotSwitch() throws {
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        let row = try openRepoWorkspace(in: c)
        row.mouseEntered(with: crossing(.mouseEntered, over: row))

        try clickThroughTheWindow(at: try XCTUnwrap(row.hoverAccessory), in: c)

        _ = try newWorktreeCard(in: c)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, home, "the ＋ takes the click, not the row")
    }

    func test_cancellingACardOpenedFromTheSidebar_closesIt_ratherThanOpeningThePicker() throws {
        let c = makeWindow()
        let row = try openRepoWorkspace(in: c)
        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        try clickThroughTheWindow(at: try XCTUnwrap(row.hoverAccessory), in: c)
        let card = try newWorktreeCard(in: c)

        let cancel = try XCTUnwrap(descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == "Cancel" })
        cancel.performClick(nil)

        waitUntil(modals(NewWorktreeOverlay.self, in: c).isEmpty, "the card to close")
        var loaded = false
        ConfigLoader.loadWorkspaces { _ in loaded = true }
        waitUntil(loaded, "any picker load the cancel started to land")
        XCTAssertTrue(modals(RepoPickerOverlay.self, in: c).isEmpty)
    }

    private func button(_ title: String, in view: NSView) throws -> AppButton {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? AppButton }.first { $0.title == title })
    }

    private func editWorkspace(from card: NewWorktreeOverlay, in c: WindowController) throws -> AddWorkspaceOverlay {
        try button("Choose what to copy", in: card).onTap()
        waitUntil(!modals(AddWorkspaceOverlay.self, in: c).isEmpty, "the workspace form to be presented")
        return try XCTUnwrap(modals(AddWorkspaceOverlay.self, in: c).first)
    }

    private func openCardFromThePlus(in c: WindowController) throws -> NewWorktreeOverlay {
        let row = try openRepoWorkspace(in: c)
        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        try clickThroughTheWindow(at: try XCTUnwrap(row.hoverAccessory), in: c)
        return try newWorktreeCard(in: c)
    }

    func test_savingAnEditFromASidebarCard_returnsToTheCard_ratherThanThePicker() throws {
        let c = makeWindow()
        let form = try editWorkspace(from: try openCardFromThePlus(in: c), in: c)

        try button("Save", in: form).onTap()

        _ = try newWorktreeCard(in: c)
        XCTAssertTrue(modals(RepoPickerOverlay.self, in: c).isEmpty)
    }

    func test_savingAPathEditFromASidebarCard_returnsToTheCard_forTheMovedWorkspace() throws {
        let c = makeWindow()
        let moved = try GitFixture.makeRepo(at: tempRoot.appendingPathComponent("moved", isDirectory: true))
        let form = try editWorkspace(from: try openCardFromThePlus(in: c), in: c)
        let path = try XCTUnwrap(
            descendants(of: form).compactMap { $0 as? FieldBox }.first { $0.placeholder == "Type a path, or Choose" })

        path.setText(moved.path)
        try button("Save", in: form).onTap()

        let card = try newWorktreeCard(in: c)
        XCTAssertTrue(modals(ToastView.self, in: c).isEmpty, "the card finds the entry at its new folder")
        card.setBranchForTesting("feature/moved")
        try button("Create Worktree", in: card).performClick(nil)
        waitUntil(
            rows(of: c).map(\.titleForTesting).contains("feature/moved"), "the new worktree's row", timeout: 10)
        let branches = try WorktreeStore.list(in: moved).compactMap(\.branch)
        XCTAssertTrue(branches.contains("feature/moved"), "the worktree is cut from the moved folder's repo")
    }

    func test_creatingFromThePlus_nestsTheNewWorktreeUnderItsWorkspace_andMakesItActive() throws {
        let c = makeWindow()
        let row = try openRepoWorkspace(in: c)
        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        try clickThroughTheWindow(at: try XCTUnwrap(row.hoverAccessory), in: c)
        let card = try newWorktreeCard(in: c)

        card.setBranchForTesting("feature/nested")
        let create = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title.hasPrefix("Create") })
        create.performClick(nil)

        waitUntil(rows(of: c).count == 3, "the new worktree's row", timeout: 10)
        XCTAssertEqual(rows(of: c).map(\.titleForTesting), ["Home", "Repo", "feature/nested"])
        XCTAssertEqual(rows(of: c)[2].variant, .nested(symbol: "arrow.triangle.branch"))
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting.last)
    }

    func test_neitherTheDefaultWorkspace_norAWorktree_offersNewWorktree() throws {
        let c = makeWindow()
        let row = try openRepoWorkspace(in: c)
        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        try clickThroughTheWindow(at: try XCTUnwrap(row.hoverAccessory), in: c)
        let card = try newWorktreeCard(in: c)
        card.setBranchForTesting("feature/plain")
        try XCTUnwrap(descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title.hasPrefix("Create") })
            .performClick(nil)
        waitUntil(rows(of: c).count == 3, "the new worktree's row", timeout: 10)
        drainGitStatus()

        XCTAssertNil(rows(of: c)[0].hoverAccessory, "Home has no config entry")
        XCTAssertNotNil(rows(of: c)[1].hoverAccessory)
        XCTAssertNil(rows(of: c)[2].hoverAccessory, "a worktree is made from its workspace")
    }

    private func create(_ branch: String, from row: SettingsNavRow, in c: WindowController) throws {
        let before = rows(of: c).count
        row.mouseEntered(with: crossing(.mouseEntered, over: row))
        try clickThroughTheWindow(at: try XCTUnwrap(row.hoverAccessory), in: c)
        let card = try newWorktreeCard(in: c)
        card.setBranchForTesting(branch)
        try XCTUnwrap(descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title.hasPrefix("Create") })
            .performClick(nil)
        waitUntil(rows(of: c).count == before + 1, "the new worktree's row", timeout: 10)
    }

    private func ghostWithAWorktree(in c: WindowController) throws -> SettingsNavRow {
        try create("feature/first", from: try openRepoWorkspace(in: c), in: c)
        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[1])
        c.handle(.closeWorkspace)
        let ghost = rows(of: c)[1]
        XCTAssertEqual(ghost.variant, .faint)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return ghost
    }

    func test_creatingFromAGhostsPlus_nestsTheNewWorktreeUnderTheGhost_withoutOpeningItsWorkspace() throws {
        let c = makeWindow()
        let ghost = try ghostWithAWorktree(in: c)

        try create("feature/second", from: ghost, in: c)

        XCTAssertEqual(rows(of: c).map(\.titleForTesting), ["Home", "Repo", "feature/first", "feature/second"])
        XCTAssertEqual(rows(of: c)[1].variant, .faint, "the workspace stays closed")
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting.last)
    }

    func test_optReturn_onAFocusedGhost_opensNewWorktree() throws {
        let c = makeWindow()
        c.window.makeKeyAndOrderFront(nil)
        let ghost = try ghostWithAWorktree(in: c)
        ghost.takeKeyboardFocus()
        XCTAssertTrue(c.window.firstResponder === ghost)

        XCTAssertNil(interceptor(for: c).route(try optionReturn(in: c)))

        _ = try newWorktreeCard(in: c)
    }

    private func interceptor(for c: WindowController) -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { c.handle($0) }
        keys.passThroughGuard = { _, action in
            PickerChordGuard.shouldPassThrough(
                action: action, repoPickerIsOpen: c.isRepoPickerOpen, sidebarHasFocus: c.isSidebarFocused)
        }
        return keys
    }

    private func optionReturn(in c: WindowController) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    func test_optReturn_onAFocusedWorkspaceRow_opensNewWorktree() throws {
        let c = makeWindow()
        c.window.makeKeyAndOrderFront(nil)
        _ = try openRepoWorkspace(in: c)
        c.activateWorkspaceForTesting(try XCTUnwrap(c.workspaceIDsForTesting.last))
        c.handle(.focusSidebar)
        XCTAssertTrue(c.window.firstResponder === rows(of: c).last)

        XCTAssertNil(interceptor(for: c).route(try optionReturn(in: c)), "the sidebar claims the chord")

        _ = try newWorktreeCard(in: c)
    }

    func test_optReturn_onARowThatMakesNoWorktrees_opensNothing_andNeverReachesThePane() throws {
        let c = makeWindow()
        c.window.makeKeyAndOrderFront(nil)
        _ = try openRepoWorkspace(in: c)
        c.handle(.focusSidebar)
        XCTAssertTrue(c.window.firstResponder === rows(of: c).first)

        XCTAssertNil(interceptor(for: c).route(try optionReturn(in: c)))

        var loaded = false
        ConfigLoader.loadWorkspaces { _ in loaded = true }
        waitUntil(loaded, "any load the chord started to land")
        XCTAssertTrue(modals(NewWorktreeOverlay.self, in: c).isEmpty)
        XCTAssertTrue(modals(ToastView.self, in: c).isEmpty, "a row with no ＋ does nothing at all")
    }

    func test_optReturn_withThePaneFocused_stillReachesThePane() throws {
        let c = makeWindow()
        c.window.makeKeyAndOrderFront(nil)
        _ = try openRepoWorkspace(in: c)
        let event = try optionReturn(in: c)

        XCTAssertTrue(interceptor(for: c).route(event) === event)
    }

    private func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = [], in c: WindowController
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func rightClick(_ row: SettingsNavRow, in c: WindowController) throws {
        row.rightMouseDown(with: try mouse(.rightMouseDown, at: .zero, in: c))
    }

    private var menu: SidebarRowMenu { controller!.sidebarForTesting.view.rowMenu }

    func test_rightClickingAWorkspaceRow_opensItsMenu_withoutSwitching() throws {
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        let row = try openRepoWorkspace(in: c)

        try rightClick(row, in: c)

        XCTAssertTrue(menu.isOpen)
        XCTAssertEqual(menu.itemViewsForTesting.map(\.title), ["New Worktree…", "Close Workspace"])
        XCTAssertEqual(menu.itemViewsForTesting.map(\.shortcutForTesting), ["⌥⏎", "⌘⌥W"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, home, "a right-click never switches")
    }

    func test_controlClickingAWorkspaceRow_opensItsMenu_withoutSwitching() throws {
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        let row = try openRepoWorkspace(in: c)

        row.mouseDown(with: try mouse(.leftMouseDown, at: .zero, flags: .control, in: c))

        XCTAssertTrue(menu.isOpen)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, home)
    }

    func test_choosingNewWorktreeFromTheMenu_opensTheCard_andClosesTheMenu() throws {
        let c = makeWindow()
        let row = try openRepoWorkspace(in: c)
        try rightClick(row, in: c)
        let item = try XCTUnwrap(menu.itemViewsForTesting.first)

        try clickThroughTheWindow(at: item, in: c)

        _ = try newWorktreeCard(in: c)
        XCTAssertFalse(menu.isOpen)
    }

    func test_escape_closesTheMenu_andGoesNoFurther() throws {
        let c = makeWindow()
        try rightClick(try openRepoWorkspace(in: c), in: c)
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))

        XCTAssertNil(menu.filter(escape))

        XCTAssertFalse(menu.isOpen)
        XCTAssertTrue(modals(SidebarRowMenuItemView.self, in: c).isEmpty)
    }

    func test_aClickElsewhere_closesTheMenu_andStillLands() throws {
        let c = makeWindow()
        try rightClick(try openRepoWorkspace(in: c), in: c)
        let click = try mouse(.leftMouseDown, at: NSPoint(x: 600, y: 300), in: c)

        XCTAssertTrue(menu.filter(click) === click)

        XCTAssertFalse(menu.isOpen)
    }

    func test_aClickOnTheMenu_leavesItForTheItem() throws {
        let c = makeWindow()
        try rightClick(try openRepoWorkspace(in: c), in: c)
        let item = try XCTUnwrap(menu.itemViewsForTesting.first)
        let click = try mouse(
            .leftMouseDown, at: item.convert(NSPoint(x: item.bounds.midX, y: item.bounds.midY), to: nil), in: c)

        XCTAssertTrue(menu.filter(click) === click)

        XCTAssertTrue(menu.isOpen)
    }

    func test_aRowWithNoConfigEntry_offersOnlyClose() throws {
        let c = makeWindow()
        _ = try openRepoWorkspace(in: c)

        try rightClick(rows(of: c)[0], in: c)

        XCTAssertEqual(menu.itemViewsForTesting.map(\.title), ["Close Workspace"], "Home has no config entry")
    }

    func test_collapsingTheSidebar_closesTheMenu() throws {
        let c = makeWindow()
        try rightClick(try openRepoWorkspace(in: c), in: c)
        XCTAssertTrue(menu.isOpen)

        c.handle(.toggleSidebar)

        waitUntil(!menu.isOpen, "the menu to close with the sidebar")
        XCTAssertTrue(modals(SidebarRowMenuItemView.self, in: c).isEmpty)
    }

    func test_theWindowResigningKey_closesTheMenu() throws {
        let c = makeWindow()
        try rightClick(try openRepoWorkspace(in: c), in: c)
        XCTAssertTrue(menu.isOpen)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: c.window)

        waitUntil(!menu.isOpen, "the menu to close with the window's focus")
        XCTAssertTrue(modals(SidebarRowMenuItemView.self, in: c).isEmpty)
    }

    private func drainGitStatus() {
        var landed = false
        GitRepoStatus.refresh([repo]) { landed = true }
        waitUntil(landed, "the branch reads to land")
    }
}
