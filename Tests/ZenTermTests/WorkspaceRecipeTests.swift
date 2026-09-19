import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WorkspaceRecipeTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { false }
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        super.tearDown()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func panels(in controller: WindowController) -> [PanelHostView] {
        guard let root = controller.window.contentView else { return [] }
        return descendants(of: root).compactMap { $0 as? PanelHostView }
    }

    private func revealedDrawerCount(in controller: WindowController) -> Int {
        panels(in: controller).filter(\.isHeaderVisibleForTesting).count
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        return controller
    }

    private func bothDrawers() -> Workspace {
        Workspace(
            title: "probe", path: URL(fileURLWithPath: NSTemporaryDirectory()), main: nil,
            right: "shell", bottom: "shell", focus: .main, env: [:])
    }

    private func focusedOnTheRightDrawer() -> Workspace {
        Workspace(
            title: "probe", path: URL(fileURLWithPath: NSTemporaryDirectory()), main: nil,
            right: "shell", bottom: "shell", focus: .right, env: [:])
    }

    func test_opening_revealsTheWorkspacesDrawersInTheSameTurn() {
        let controller = makeController()
        XCTAssertEqual(revealedDrawerCount(in: controller), 0, "the launch tab has no drawers open")

        controller.openWorkspaceForTesting(bothDrawers())

        XCTAssertEqual(
            revealedDrawerCount(in: controller), 2,
            "a workspace swaps in without canvas motion, so there is nothing to stage its drawers behind")
    }

    func test_reduceMotion_appliesTheRecipeAfterStart_soItsFocusSticks() {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()

        controller.openWorkspaceForTesting(focusedOnTheRightDrawer())

        XCTAssertEqual(
            revealedDrawerCount(in: controller), 2, "the recipe opens both drawers it names")
        let focused = panels(in: controller).filter { $0.haloOpacityForTesting > 0 }
        XCTAssertEqual(focused.count, 1, "exactly one region holds the tab's focus")
        XCTAssertTrue(
            focused.first?.isHeaderVisibleForTesting == true,
            "the recipe's focus landed on a drawer and stayed there, rather than being taken back "
                + "by the main pane because the recipe ran before the tab started")
    }
}
