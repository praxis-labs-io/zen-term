import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The diff viewer's off-main open path (ZEN-234). The repo-root walk is filesystem I/O, so
/// `openDiffViewer()` resolves it off the main thread and presents on the hop back — which means it
/// must NOT present within its own turn, and a second ⌘D landing in the resolve gap must not queue
/// a second viewer. Both are things a state-only check would miss (the modal slot only fills after
/// the resolve), so they're driven through the real controller with an injected resolver.
@MainActor
final class WindowControllerDiffViewerTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }  // synchronous spring, so teardown sees a settled tree
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-diff-viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.showAndStart()
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func diffOverlays(_ c: WindowController) -> [DiffViewerOverlay] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? DiffViewerOverlay }
    }

    /// `openDiffViewer()` must not present synchronously — the repo-root resolve is off-main. Once
    /// the resolve lands with a root, the viewer is up.
    func test_openDiffViewer_presentsOnlyAfterOffMainResolve() {
        let c = makeWindow()
        var pending: [(URL?) -> Void] = []
        c.resolveRepoRoot = { _, completion in pending.append(completion) }

        c.openDiffViewer()
        XCTAssertFalse(c.isModalOverlayOpen, "the viewer must not present before the root resolves")
        XCTAssertEqual(pending.count, 1)

        pending[0](root)
        XCTAssertTrue(c.isModalOverlayOpen)
        XCTAssertEqual(diffOverlays(c).count, 1, "the diff viewer is up once the root resolves")
    }

    /// No enclosing repo → a toast, no viewer.
    func test_openDiffViewer_noRepo_showsToastAndNoViewer() {
        let c = makeWindow()
        c.resolveRepoRoot = { _, completion in completion(nil) }

        c.openDiffViewer()

        XCTAssertFalse(c.isModalOverlayOpen)
        XCTAssertTrue(diffOverlays(c).isEmpty, "a non-repo must not present a viewer")
    }

    /// Two tabs on two repos each keep their own session (ZEN-298). The slot used to live on
    /// `WindowController`, so opening the viewer in a second tab on a different repo evicted the
    /// first tab's session; going back rebuilt from nothing, which the reader sees as a spinner and
    /// the top of the file they were part-way through.
    ///
    /// Identity is the assertion because the session *is* the preserved place: `DiffViewerOverlay`
    /// keeps its `session` private and seeds `pendingPlace` from it on open, so a surviving session
    /// is exactly what "lands you back where you left off" means.
    func test_diffViewerSession_survivesAnotherTabOpeningAnotherRepo() throws {
        let c = makeWindow()
        let repoB = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-diff-viewer-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repoB.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoB) }

        // Tab 0 reads repo A, and the reader gets part-way into a file.
        c.resolveRepoRoot = { _, completion in completion(self.root) }
        c.openDiffViewer()
        let first = try XCTUnwrap(c.diffViewerSessionForTesting(tabIndex: 0))
        c.openDiffViewer()  // ⌘D again dismisses it; every other chord is swallowed while it's up
        // Stamped after the dismiss, because dismissing runs `snapshotPlace()` and that is what
        // writes the reader's real place into the session — stamping before it would just be
        // overwritten by the empty place of a viewer nobody scrolled.
        first.place.selectedPath = "Sources/ZenTerm/WindowController.swift"

        // A second tab opens the viewer on a different repo.
        c.newTabForTesting()
        c.selectTabForTesting(index: 1)
        c.resolveRepoRoot = { _, completion in completion(repoB) }
        c.openDiffViewer()
        XCTAssertEqual(
            c.diffViewerSessionForTesting(tabIndex: 1)?.repoRoot, repoB,
            "the second tab reads its own repo")
        c.openDiffViewer()

        // Back in tab 0: the same session, still holding where the reader was.
        c.selectTabForTesting(index: 0)
        let returned = try XCTUnwrap(c.diffViewerSessionForTesting(tabIndex: 0))
        XCTAssertTrue(
            returned === first, "tab 0's session must survive another tab opening another repo")
        XCTAssertEqual(
            returned.place.selectedPath, "Sources/ZenTerm/WindowController.swift",
            "the reader's place comes back with it")
    }

    /// The eviction that *should* still happen: one tab, two repos. A session is per repo, so
    /// pointing the same tab at a different repo starts fresh rather than accumulating one session
    /// per repo the tab has ever visited.
    func test_diffViewerSession_sameTabDifferentRepo_startsFresh() throws {
        let c = makeWindow()
        let repoB = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-diff-viewer-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repoB.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoB) }

        c.resolveRepoRoot = { _, completion in completion(self.root) }
        c.openDiffViewer()
        let first = try XCTUnwrap(c.diffViewerSessionForTesting(tabIndex: 0))
        c.openDiffViewer()  // dismiss before pointing the same tab at another repo

        c.resolveRepoRoot = { _, completion in completion(repoB) }
        c.openDiffViewer()
        let second = try XCTUnwrap(c.diffViewerSessionForTesting(tabIndex: 0))

        XCTAssertFalse(second === first, "a different repo in the same tab starts a new session")
        XCTAssertEqual(second.repoRoot, repoB)
    }

    /// A second ⌘D in the resolve gap is dropped, not queued — otherwise the resolve completion
    /// would present a second viewer over the first.
    func test_openDiffViewer_doublePressMidResolve_presentsOne() {
        let c = makeWindow()
        var pending: [(URL?) -> Void] = []
        c.resolveRepoRoot = { _, completion in pending.append(completion) }

        c.openDiffViewer()
        c.openDiffViewer()  // second press before the first resolve lands
        XCTAssertEqual(pending.count, 1, "the second press must not start a second resolve")

        pending[0](root)
        XCTAssertEqual(diffOverlays(c).count, 1, "exactly one viewer, not two stacked")
    }
}
