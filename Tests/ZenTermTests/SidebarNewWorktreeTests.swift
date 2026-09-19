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

    private func drainGitStatus() {
        var landed = false
        GitRepoStatus.refresh([repo]) { landed = true }
        waitUntil(landed, "the branch reads to land")
    }
}
