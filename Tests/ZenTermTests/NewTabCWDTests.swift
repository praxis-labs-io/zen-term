import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class NewTabCWDTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-new-tab-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindowInRoot() throws -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.mountAndStart()
        controller = c
        try XCTUnwrap(spawned.first).currentDirectory = root
        return c
    }

    private func inheritCWD(_ on: Bool) {
        var config = GeneralConfig.builtIn
        config.tabInheritCWD = on
        GeneralConfig.setCurrentForTesting(config)
    }

    func test_newTab_startsAtHomeByDefault() throws {
        XCTAssertFalse(GeneralConfig.builtIn.tabInheritCWD, "home is the shipped default")
        let c = try makeWindowInRoot()

        c.newTabForTesting()

        let tab = try XCTUnwrap(spawned.last)
        XCTAssertEqual(tab.lastConfig?.workingDirectory, ShellLaunch.defaultCWD)
    }

    func test_newTab_inheritsTheFocusedCWDWhenOptedIn() throws {
        let c = try makeWindowInRoot()
        inheritCWD(true)

        c.newTabForTesting()

        let tab = try XCTUnwrap(spawned.last)
        XCTAssertEqual(tab.lastConfig?.workingDirectory, root)
    }

    func test_newTab_inARemovedWorktree_startsAtHomeNotItsDeletedFolder() throws {
        let c = try makeWindowInRoot()
        inheritCWD(true)
        let parent = Workspace(
            title: "alpha", path: FileManager.default.temporaryDirectory, main: nil, right: nil, bottom: nil,
            focus: .main, env: [:])
        let worktree = Worktree(path: root, branch: "one", head: "0000000", isLocked: false)
        c.openWorkspaceForTesting(
            Workspace(title: "alpha: one", path: root, main: nil, right: nil, bottom: nil, focus: .main, env: [:]),
            origin: WorktreeOrigin(parent: parent, worktree: worktree))
        try XCTUnwrap(spawned.last).currentDirectory = root
        WorktreeStore.isRemovedOverrideForTesting = { _ in true }
        c.checkForRemovedWorktreesForTesting()
        waitUntil(c.runningWorkspaces().contains { $0.removedWorktree != nil }, "the worktree to read removed")

        c.newTabForTesting()

        let tab = try XCTUnwrap(spawned.last)
        XCTAssertEqual(tab.lastConfig?.workingDirectory, ShellLaunch.defaultCWD)
    }

    func test_split_inheritsTheCWDRegardlessOfTheKey() throws {
        let c = try makeWindowInRoot()

        c.handle(.splitVertical)

        let pane = try XCTUnwrap(spawned.last)
        XCTAssertEqual(pane.lastConfig?.workingDirectory, root)
    }

    func test_newSessionCWD_isTheOneRuleBothChordsRead() {
        XCTAssertNil(ShellLaunch.newSessionCWD(focused: root), "home by default, whatever is focused")

        inheritCWD(true)
        XCTAssertEqual(ShellLaunch.newSessionCWD(focused: root), root)
        XCTAssertNil(ShellLaunch.newSessionCWD(focused: nil), "an unresolvable pane still means home")
    }
}
