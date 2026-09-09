import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Which tabs belong to a folder that is about to be deleted, and closing them. Removing a worktree
/// asks this of every window, and getting it wrong leaves a shell running inside a folder that is
/// gone.
@MainActor
final class WindowControllerTabsAtPathTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-tabs-at-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.mountAndStart()
        controller = c
        return c
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func workspace(_ title: String, at path: URL) -> Workspace {
        Workspace(
            title: title, path: path, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
    }

    // MARK: tests

    func test_countsOnlyTheTabsOpenedAtThatPath() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        let other = try folder("feature-y")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)
        c.openWorkspaceForTesting(workspace("x again", at: wanted), replaceCurrentTab: false)
        c.openWorkspaceForTesting(workspace("y", at: other), replaceCurrentTab: false)

        XCTAssertEqual(c.tabCount(atPath: wanted), 2)
        XCTAssertEqual(c.tabCount(atPath: other), 1)
    }

    /// The match is on where the tab was opened, not where its shell now is. A tab whose shell has
    /// `cd`'d out still belongs to the worktree, and matching the live cwd would leave that tab
    /// running inside the folder being deleted.
    func test_aTabWhoseShellHasMovedStillCounts() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)
        spawned.forEach { $0.currentDirectory = URL(fileURLWithPath: "/somewhere/else") }

        XCTAssertEqual(c.tabCount(atPath: wanted), 1)
    }

    func test_anUnstandardizedPathMatchesTheTabItOpened() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)

        let noisy = wanted.deletingLastPathComponent()
            .appendingPathComponent(".").appendingPathComponent("feature-x")
        XCTAssertEqual(c.tabCount(atPath: noisy), 1)
    }

    func test_closesExactlyThoseTabs_andLeavesTheOthers() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        let other = try folder("feature-y")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)
        c.openWorkspaceForTesting(workspace("y", at: other), replaceCurrentTab: false)
        c.openWorkspaceForTesting(workspace("x again", at: wanted), replaceCurrentTab: false)
        let before = c.tabOrderForTesting.count

        c.closeTabs(atPath: wanted)

        XCTAssertEqual(c.tabCount(atPath: wanted), 0)
        XCTAssertEqual(c.tabCount(atPath: other), 1)
        XCTAssertEqual(c.tabOrderForTesting.count, before - 2)
    }

    /// The reported bug: confirming closed the tab, which closed the window, which took the picker
    /// showing the progress with it. Nothing may go until the folder actually has.
    func test_aRemovalThatHasOnlyStarted_leavesTheTabOpen() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)

        c.worktreeRemovalsChanged(.began(wanted))

        XCTAssertEqual(c.tabCount(atPath: wanted), 1)
    }

    func test_aRemovalThatLanded_closesTheTab() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)

        c.worktreeRemovalsChanged(.removed(wanted))

        XCTAssertEqual(c.tabCount(atPath: wanted), 0)
    }

    /// The folder is still there, so the shell in it is still working.
    func test_aRemovalThatFailed_leavesTheTabOpen() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)

        c.worktreeRemovalsChanged(.failed(wanted))

        XCTAssertEqual(c.tabCount(atPath: wanted), 1)
    }

    /// A ⌘T from a worktree tab inherits the shell's cwd, which is a subdirectory of it. That tab
    /// is in the folder being deleted just the same, so the confirm has to count it and the
    /// removal has to close it.
    func test_aTabOpenedInsideTheWorktreeCountsAndCloses() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        let inside = try folder("feature-x/src")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)
        c.openWorkspaceForTesting(workspace("x/src", at: inside), replaceCurrentTab: false)

        XCTAssertEqual(c.tabCount(atPath: wanted), 2)

        c.closeTabs(atPath: wanted)
        XCTAssertEqual(c.tabCount(atPath: wanted), 0)
    }

    /// A sibling whose name merely starts the same is a different folder.
    func test_aSiblingSharingAPathPrefixIsNotInside() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        _ = try folder("feature-x-old")
        c.openWorkspaceForTesting(
            workspace("old", at: root.appendingPathComponent("feature-x-old", isDirectory: true)),
            replaceCurrentTab: false)

        XCTAssertEqual(c.tabCount(atPath: wanted), 0)
    }

    func test_aPathNothingWasOpenedAtClosesNothing() throws {
        let c = makeWindow()
        let wanted = try folder("feature-x")
        c.openWorkspaceForTesting(workspace("x", at: wanted), replaceCurrentTab: false)
        let before = c.tabOrderForTesting.count

        c.closeTabs(atPath: try folder("never-opened"))

        XCTAssertEqual(c.tabOrderForTesting.count, before)
    }
}
