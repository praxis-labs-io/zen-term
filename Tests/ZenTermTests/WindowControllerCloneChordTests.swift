import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// ⌥⏎ over the picker's selected workspace row starts cloning it: a placeholder row appears
/// immediately, and becomes a normal clone row once `CloneStore.create` returns, opened with the
/// same ⏎/⇧⏎ as any other row. Driven through a real `WindowController`, not a synthesized
/// `performKeyEquivalent` call — that turned out not to fire while the picker's search field holds
/// focus, which is what made the first attempt at this feature look broken.
@MainActor
final class WindowControllerCloneChordTests: WindowTestCase {
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
            .appendingPathComponent("zenterm-clone-chord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        CloneStore.rootOverrideForTesting = tempRoot.appendingPathComponent("clones", isDirectory: true)
        repo = try makeRepoWithOrigin()
        try seedWorkspaces(
            """
            [Zen Term]
            path = \(repo.path)
            """)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        CloneStore.rootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: fixtures

    private func makeRepoWithOrigin() throws -> URL {
        let origin = tempRoot.appendingPathComponent("origin.git", isDirectory: true)
        let work = tempRoot.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        for args in [
            ["init", "--bare", "--initial-branch=main"]
        ] { try GitCommand.run(args, in: origin).get() }
        for args in [
            ["init", "--initial-branch=main"], ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test"],
        ] { try GitCommand.run(args, in: work).get() }
        try "one\n".write(to: work.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "."], ["commit", "-m", "first"], ["remote", "add", "origin", origin.path]] {
            try GitCommand.run(args, in: work).get()
        }
        try GitCommand.run(["push", "-u", "origin", "main"], in: work).get()
        return work
    }

    private func seedWorkspaces(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
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

    private func picker(in c: WindowController) -> RepoPickerOverlay? {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }.first
    }

    private func waitForPickerToOpen(_ c: WindowController) {
        waitUntil(picker(in: c) != nil, "the picker to be presented")
    }

    private func workspace() -> Workspace {
        Workspace(title: "Zen Term", path: repo, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
    }

    // MARK: tests

    func test_cloneWorkspaceChord_showsAPendingRow_thenTheRealCloneOpensOnReturn() {
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitForPickerToOpen(c)
        XCTAssertEqual(picker(in: c)?.selectedWorkspace?.title, "Zen Term")

        c.handle(.cloneWorkspace)

        // The picker stays open with a placeholder row while the clone is made.
        XCTAssertTrue(c.isModalOverlayOpen, "the picker stays open while the clone is made")
        XCTAssertTrue(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.PendingCloneRowView } == true,
            "a placeholder row appears immediately")

        waitUntil(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.CloneRowView } == true,
            "the placeholder to become the real clone row")
        XCTAssertFalse(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.PendingCloneRowView } == true,
            "the placeholder is gone once the clone lands")

        // Selecting the new row and pressing Return opens it, the same as any other row.
        picker(in: c)?.control(
            NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        picker(in: c)?.control(
            NSTextField(), textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))

        waitUntil(!c.isModalOverlayOpen, "the picker to close once the clone is opened")
        let expected = CloneStore.root
            .appendingPathComponent(CloneStore.directoryName(for: workspace()))
            .appendingPathComponent("\(CloneStore.slug(for: workspace()))-c2")
        waitUntil(c.focusedCWD == expected, "the clone's tab to open")
    }

    func test_cloneWorkspaceChord_withNoModalOpen_doesNotClone() {
        let c = makeWindow()

        c.handle(.cloneWorkspace)

        XCTAssertTrue(
            CloneStore.list(for: [workspace()]).isEmpty,
            "the chord has no meaning outside the picker")
    }

    func test_cloneWorkspaceChord_overTheAddRow_doesNothing() {
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitForPickerToOpen(c)
        picker(in: c)?.control(
            NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:)))
        XCTAssertNil(picker(in: c)?.selectedWorkspace)

        c.handle(.cloneWorkspace)

        XCTAssertTrue(CloneStore.list(for: [workspace()]).isEmpty)
    }

    func test_defaultChord_isOptionReturn() {
        XCTAssertEqual(KeymapDefaults.map[Chord(option: true, key: "⏎")], .cloneWorkspace)
    }
}
