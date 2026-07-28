import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A ⏎ workspace open stages its recipe behind the canvas slide: the tab arrives, *then* its
/// drawers push open, because a drawer travelling the same direction as the canvas it rides in on
/// has no readable motion of its own. The staging runs from the slide's completion, which is the
/// silently-dead part — a dropped callback, a guard that never passes, or a released controller
/// leaves the workspace open with no drawers at all and nothing on screen to say a step was
/// skipped. A ⇧⏎ replace has no motion to wait for and must still apply its recipe inline.
@MainActor
final class WorkspaceRecipeStagingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalReduceMotion: (() -> Bool)!
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        // Staging is only observable while the slide is in flight, and Reduce Motion collapses it.
        // Pin it off by default so the developer's own accessibility setting can't turn the
        // staging tests into no-ops; the Reduce Motion test below opts back in explicitly.
        originalReduceMotion = Motion.isReduceMotionEnabled
        Motion.isReduceMotionEnabled = { false }
        originalOverride = TerminalSurfaceFactory.makeOverride
        // Headless surfaces: no libghostty, and an idle tab, so a replace isn't gated by the
        // "Replace Tab" confirm a busy one raises (ZEN-213).
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        Motion.isReduceMotionEnabled = originalReduceMotion
        super.tearDown()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func panels(in controller: WindowController) -> [PanelHostView] {
        guard let root = controller.window.contentView else { return [] }
        return descendants(of: root).compactMap { $0 as? PanelHostView }
    }

    /// Revealed drawers in the window. A drawer carries an always-on header; a resting pane's is
    /// hidden, which is what separates the two — every panel is a `PanelHostView`.
    private func revealedDrawerCount(in controller: WindowController) -> Int {
        panels(in: controller).filter(\.isHeaderVisibleForTesting).count
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        self.controller = controller
        controller.showAndStart()
        return controller
    }

    /// Both drawers named, so a revealed recipe shows two.
    private func bothDrawers() -> Workspace {
        Workspace(
            title: "probe", path: URL(fileURLWithPath: NSTemporaryDirectory()), main: nil,
            right: "shell", bottom: "shell", focus: .main, env: [:])
    }

    /// The same recipe, but landing focus on a drawer — the only part of a recipe whose result
    /// differs depending on whether it ran before or after the tab started.
    private func focusedOnTheRightDrawer() -> Workspace {
        Workspace(
            title: "probe", path: URL(fileURLWithPath: NSTemporaryDirectory()), main: nil,
            right: "shell", bottom: "shell", focus: .right, env: [:])
    }

    func test_enterOpen_revealsTheDrawersOnceTheCanvasLands() {
        let controller = makeController()
        XCTAssertEqual(revealedDrawerCount(in: controller), 0, "the launch tab has no drawers open")

        controller.openWorkspaceForTesting(bothDrawers(), replaceCurrentTab: false)

        XCTAssertEqual(
            revealedDrawerCount(in: controller), 0,
            "the recipe is staged: no drawer is revealed while the canvas is still travelling")
        waitUntil(
            revealedDrawerCount(in: controller) == 2,
            "both of the workspace's drawers to open once the canvas slide lands")
    }

    /// Reduce Motion collapses the slide, and `Motion.slideSwap` then runs its completion
    /// synchronously, inside `mount` — before `installController` has reached `c.start()`. Staging
    /// through that completion puts the recipe ahead of the tab's own start, breaking the order
    /// `applyRecipe`'s contract depends on ("called once right after `start()`"): `start()` ends in
    /// `focusFrontmost()`, so a recipe applied first has its `focus: right` immediately taken back
    /// by the main pane. The drawers still open either way, so the ordering is only visible in
    /// which region ends up wearing the focus halo.
    func test_reduceMotion_appliesTheRecipeAfterStart_soItsFocusSticks() {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()

        controller.openWorkspaceForTesting(focusedOnTheRightDrawer(), replaceCurrentTab: false)

        XCTAssertEqual(
            revealedDrawerCount(in: controller), 2, "the recipe opens both drawers it names")
        let focused = panels(in: controller).filter { $0.haloOpacityForTesting > 0 }
        XCTAssertEqual(focused.count, 1, "exactly one region holds the tab's focus")
        XCTAssertTrue(
            focused.first?.isHeaderVisibleForTesting == true,
            "the recipe's focus landed on a drawer and stayed there, rather than being taken back "
                + "by the main pane because the recipe ran before the tab started")
    }

    func test_shiftEnterReplace_appliesTheRecipeInline() {
        let controller = makeController()

        controller.openWorkspaceForTesting(bothDrawers(), replaceCurrentTab: true)

        XCTAssertEqual(
            revealedDrawerCount(in: controller), 2,
            "a replace has no canvas motion to stage behind, so its drawers open in the same turn")
    }
}
