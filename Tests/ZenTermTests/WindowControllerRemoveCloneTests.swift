import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// ⌥⌫ over a selected clone row: confirm, then delete the directory, drop the row, and close any
/// tab that was open on it. Driven through a real `WindowController` for the same reason the clone
/// chord is: `KeyInterceptor`'s monitor sits ahead of the responder chain, so nothing below it
/// proves the keyboard path works.
@MainActor
final class WindowControllerRemoveCloneTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var second: WindowController?
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
            .appendingPathComponent("zenterm-remove-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        CloneStore.rootOverrideForTesting = tempRoot.appendingPathComponent("clones", isDirectory: true)
        repo = try makeRepoWithOrigin()
        try "[Zen Term]\npath = \(repo.path)\n"
            .write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        second?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        second = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        CloneStore.rootOverrideForTesting = nil
        CloneStore.willRemoveForTesting = nil
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
        try GitCommand.run(["init", "--bare", "--initial-branch=main"], in: origin).get()
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

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        controller = c
        return c
    }

    /// A second window sharing the first's tracker, the way `AppDelegate` wires every window.
    private func makeSecondWindow(sharing first: WindowController) -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.cloneRemovals = first.cloneRemovals
        c.mountAndStart()
        second = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func picker(in c: WindowController) -> RepoPickerOverlay? {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }.first
    }

    private func moveDown(_ c: WindowController) {
        picker(in: c)?.control(
            NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
    }

    /// Open the picker and make a clone, leaving the picker open with the clone row selected.
    @discardableResult
    private func makeCloneAndSelectIt(_ c: WindowController) -> Clone {
        c.handle(.toggleRepoPicker)
        waitUntil(picker(in: c) != nil, "the picker to be presented")
        c.handle(.cloneWorkspace)
        waitUntil(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.CloneRowView } == true,
            "the clone row to land")
        moveDown(c)  // off the workspace row, onto its clone
        return picker(in: c)!.selectedClone!.clone
    }

    /// Give the off-main `CloneStore.state` hop time to land. Asserting that no confirm appeared
    /// is only meaningful after the path that would have produced one has run.
    private func settle() {
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func confirmButton(in c: WindowController) -> NSButton? {
        descendants(of: c.window.contentView!)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Remove" }
    }

    // MARK: tests

    func test_removeCloneChord_confirmsThenDeletesTheCloneAndItsRow() throws {
        let c = makeWindow()
        let clone = makeCloneAndSelectIt(c)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path.path))

        c.handle(.removeClone)

        waitUntil(confirmButton(in: c) != nil, "the remove confirm to appear")
        confirmButton(in: c)?.performClick(nil)

        waitUntil(!FileManager.default.fileExists(atPath: clone.path.path), "the clone to be deleted")

        // The confirm closed the picker, so the row is gone with it. Reopening rescans the clones
        // directory, and that is what has to come back empty.
        c.handle(.toggleRepoPicker)
        waitUntil(picker(in: c) != nil, "the picker to reopen")
        settle()
        XCTAssertFalse(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.CloneRowView } == true,
            "the removed clone does not come back as a row")
        XCTAssertTrue(
            CloneStore.list(for: [
                Workspace(
                    title: "Zen Term", path: repo, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
            ])
            .isEmpty, "and to stop being listed")
    }

    /// Cancel is the path that must not delete anything, and it is the one a stray keystroke hits.
    func test_removeCloneChord_cancelLeavesTheCloneAlone() throws {
        let c = makeWindow()
        let clone = makeCloneAndSelectIt(c)

        c.handle(.removeClone)
        waitUntil(confirmButton(in: c) != nil, "the remove confirm to appear")
        descendants(of: c.window.contentView!)
            .compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }?
            .performClick(nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path.path))
    }

    func test_removeCloneChord_overAWorkspaceRow_doesNothing() {
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(picker(in: c) != nil, "the picker to be presented")
        XCTAssertNotNil(picker(in: c)?.selectedWorkspace, "a workspace row, not a clone")

        c.handle(.removeClone)
        settle()

        XCTAssertNil(confirmButton(in: c), "no confirm over a row that is not a clone")
        XCTAssertTrue(c.isModalOverlayOpen, "and the picker stays up")
    }

    func test_removeCloneChord_withNoModalOpen_doesNothing() {
        let c = makeWindow()
        c.handle(.removeClone)
        settle()
        XCTAssertNil(confirmButton(in: c))
    }

    /// A tab opened on the clone is a shell running in the directory about to be deleted, so it
    /// closes with it rather than being left in a path that no longer resolves.
    func test_removingAClone_closesTheTabOpenedOnIt() throws {
        let c = makeWindow()
        let clone = makeCloneAndSelectIt(c)
        let tabsBefore = c.tabCount

        // ⏎ on the selected clone row opens it in a new tab.
        picker(in: c)?.control(
            NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        waitUntil(c.tabCount == tabsBefore + 1, "the clone's tab to open")
        XCTAssertEqual(c.tabCount(atPath: clone.path), 1)

        c.handle(.toggleRepoPicker)
        waitUntil(picker(in: c) != nil, "the picker to reopen")
        moveDown(c)
        XCTAssertEqual(picker(in: c)?.selectedClone?.clone, clone)

        c.handle(.removeClone)
        waitUntil(confirmButton(in: c) != nil, "the remove confirm to appear")
        confirmButton(in: c)?.performClick(nil)

        waitUntil(c.tabCount(atPath: clone.path) == 0, "the clone's tab to close with it")
        XCTAssertEqual(c.tabCount, tabsBefore, "back to where we started")
    }

    /// A tab belongs to the clone it was opened for even after its shell has `cd`'d somewhere else,
    /// so the match is on where the tab was opened and not on where its focused pane currently is.
    /// Matching the live cwd would leave a `cd`'d tab running inside the directory being deleted.
    func test_aTabThatHasCdElsewhere_stillBelongsToTheCloneItWasOpenedFor() throws {
        let c = makeWindow()
        let clone = makeCloneAndSelectIt(c)
        picker(in: c)?.control(
            NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        waitUntil(c.tabCount(atPath: clone.path) == 1, "the clone's tab to open")

        // The shell walks out of the clone, the way a person would.
        let elsewhere = FileManager.default.temporaryDirectory
        for surface in c.allTerminalSurfacesForTesting.compactMap({ $0 as? RecordingSurface }) {
            surface.currentDirectory = elsewhere
        }

        XCTAssertEqual(c.focusedCWD, elsewhere, "the tab really is reporting a different cwd now")
        XCTAssertEqual(
            c.tabCount(atPath: clone.path), 1,
            "and it still counts as the clone's tab, so removing the clone still closes it")
    }

    /// Deleting a clone takes tens of seconds on a real repo (a quarter of a million files), and
    /// until it finishes the directory is still on disk, so the picker still lists the clone and
    /// opening that row lands in a directory being deleted. The notice has to be up for the whole
    /// of that, not a flash, or the wait is a guessing game.
    func test_removingAClone_saysSoUntilTheFilesAreGone() throws {
        let c = makeWindow()
        let clone = makeCloneAndSelectIt(c)

        c.handle(.removeClone)
        waitUntil(confirmButton(in: c) != nil, "the remove confirm to appear")
        confirmButton(in: c)?.performClick(nil)

        // Up from the moment the delete starts.
        waitUntil(removingNotice(in: c) != nil, "the removing notice to appear")

        // And down only once the clone is actually gone.
        waitUntil(!FileManager.default.fileExists(atPath: clone.path.path), "the clone to be deleted")
        waitUntil(removingNotice(in: c) == nil, "the notice to go once the files are gone")
    }

    /// The notice names the clone, so two removals in flight are tellable apart, and says why the
    /// picker has not caught up yet.
    func test_theRemovingNotice_namesTheCloneAndExplainsTheWait() throws {
        let c = makeWindow()
        let clone = makeCloneAndSelectIt(c)

        c.handle(.removeClone)
        waitUntil(confirmButton(in: c) != nil, "the remove confirm to appear")
        confirmButton(in: c)?.performClick(nil)
        waitUntil(removingNotice(in: c) != nil, "the removing notice to appear")

        let text = descendants(of: c.window.contentView!)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .filter { !$0.isEmpty }
        XCTAssertTrue(text.contains { $0.contains("Removing \(clone.title)") }, "\(text)")
        XCTAssertTrue(text.contains { $0.lowercased().contains("picker") }, "\(text)")
    }

    private func removingNotice(in c: WindowController) -> NSView? {
        descendants(of: c.window.contentView!)
            .first { view in
                descendants(of: view).contains {
                    ($0 as? NSTextField)?.stringValue.hasPrefix("Removing ") == true
                }
            }
    }

    /// The wiring the picker's removing row depends on: the window has to mark the removal in
    /// flight and hand that to the next picker it builds. Tested here rather than only on the
    /// overlay, because the overlay tests pass a set in directly and would not notice the window
    /// never filling it.
    ///
    /// A fixture clone deletes instantly, so the delete is held open on a semaphore to catch the
    /// picker mid-removal, which is the state a real 19-second delete leaves on screen.
    func test_whileARemovalIsInFlight_thePickerShowsThatRowAsRemoving() throws {
        let c = makeWindow()
        let clone = makeCloneAndSelectIt(c)

        let held = DispatchSemaphore(value: 0)
        let started = expectation(description: "the delete started")
        CloneStore.willRemoveForTesting = { _ in
            started.fulfill()
            held.wait()  // hold the clone on disk, the way a large one is held by its own size
        }

        c.handle(.removeClone)
        waitUntil(confirmButton(in: c) != nil, "the remove confirm to appear")
        confirmButton(in: c)?.performClick(nil)
        wait(for: [started], timeout: 10)

        // The clone is still on disk, so the picker still lists it. It must say what is happening.
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path.path))
        c.handle(.toggleRepoPicker)
        waitUntil(picker(in: c) != nil, "the picker to reopen mid-removal")
        waitUntil(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.RemovingCloneRowView } == true,
            "the clone's row to show as removing")
        XCTAssertFalse(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.CloneRowView } == true,
            "and not as an ordinary, openable row")

        held.signal()
        waitUntil(!FileManager.default.fileExists(atPath: clone.path.path), "the delete to finish")
    }

    /// And once it is gone, the next picker is back to normal rather than stuck on the notice.
    func test_afterTheRemovalFinishes_theRowIsSimplyAbsent() throws {
        let c = makeWindow()
        let clone = makeCloneAndSelectIt(c)

        c.handle(.removeClone)
        waitUntil(confirmButton(in: c) != nil, "the remove confirm to appear")
        confirmButton(in: c)?.performClick(nil)
        waitUntil(!FileManager.default.fileExists(atPath: clone.path.path), "the clone to be deleted")

        c.handle(.toggleRepoPicker)
        waitUntil(picker(in: c) != nil, "the picker to reopen")
        settle()
        XCTAssertFalse(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.RemovingCloneRowView } == true)
        XCTAssertFalse(
            picker(in: c)?.rowViews.contains { $0 is RepoPickerOverlay.CloneRowView } == true)
    }

    /// The guard has to be app-wide, not per window. The directory is going away whichever window
    /// is looking, so a second window listing the clone as an ordinary row would let you open a
    /// directory being deleted: the original bug, simply unfixed over there.
    func test_aRemovalStartedInOneWindow_showsAsRemovingInAnother() throws {
        let first = makeWindow()
        let clone = makeCloneAndSelectIt(first)
        let other = makeSecondWindow(sharing: first)

        let held = DispatchSemaphore(value: 0)
        let started = expectation(description: "the delete started")
        CloneStore.willRemoveForTesting = { _ in
            started.fulfill()
            held.wait()
        }

        first.handle(.removeClone)
        waitUntil(confirmButton(in: first) != nil, "the remove confirm to appear")
        confirmButton(in: first)?.performClick(nil)
        wait(for: [started], timeout: 10)

        other.handle(.toggleRepoPicker)
        waitUntil(picker(in: other) != nil, "the other window's picker to open")
        waitUntil(
            picker(in: other)?.rowViews.contains { $0 is RepoPickerOverlay.RemovingCloneRowView } == true,
            "the other window to show the row as removing too")
        XCTAssertFalse(
            picker(in: other)?.rowViews.contains { $0 is RepoPickerOverlay.CloneRowView } == true,
            "and never as an ordinary, openable row")

        held.signal()
        waitUntil(!FileManager.default.fileExists(atPath: clone.path.path), "the delete to finish")
    }
}
