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
            title: "probe", path: URL(fileURLWithPath: NSTemporaryDirectory()),
            tabs: [Workspace.Tab(right: "shell", bottom: "shell")], env: [:])
    }

    private func focusedOnTheRightDrawer() -> Workspace {
        Workspace(
            title: "probe", path: URL(fileURLWithPath: NSTemporaryDirectory()),
            tabs: [Workspace.Tab(right: "shell", bottom: "shell")],
            focus: Workspace.LaunchFocus(tab: 0, region: .right), env: [:])
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

    private func threeTabs() -> Workspace {
        Workspace(
            title: "probe", path: URL(fileURLWithPath: NSTemporaryDirectory()),
            tabs: [
                Workspace.Tab(name: "editor", main: "first-main"),
                Workspace.Tab(main: "second-main", right: "second-right"),
                Workspace.Tab(name: "gate", main: "third-main", bottom: "shell"),
            ],
            focus: Workspace.LaunchFocus(tab: 1, region: .right), env: [:])
    }

    private func launchLine(of surface: TerminalSurface?) -> String {
        (surface as? RecordingSurface)?.lastConfig?.args.last ?? ""
    }

    private func mainLaunchLines(in controller: WindowController) -> [String] {
        controller.tabOrderForTesting.map {
            launchLine(of: controller.controllerForTesting(tab: $0)?.allSurfaces.first)
        }
    }

    private func assertOpensTheThreeTabsInOrder(_ controller: WindowController, line: UInt = #line) {
        let lines = mainLaunchLines(in: controller)
        XCTAssertEqual(lines.count, 3, line: line)
        for (launched, command) in zip(lines, ["first-main", "second-main", "third-main"]) {
            XCTAssertTrue(launched.contains(command), "\(command) runs in its own tab, in order", line: line)
        }
    }

    func test_opening_startsEveryTabInOrder() {
        let controller = makeController()

        controller.openWorkspaceForTesting(threeTabs())

        assertOpensTheThreeTabsInOrder(controller)
        let second = controller.controllerForTesting(tab: controller.tabOrderForTesting[1])
        XCTAssertTrue(second?.allSurfaces.contains { launchLine(of: $0).contains("second-right") } == true)
    }

    func test_namedTabsPinTheirTitle_andUnnamedOnesStayLive() throws {
        let controller = makeController()

        controller.openWorkspaceForTesting(threeTabs())

        let tabs = controller.tabOrderForTesting
        XCTAssertEqual(controller.tabTitlesForTesting[0], "editor")
        XCTAssertEqual(controller.tabTitlesForTesting[2], "gate")
        XCTAssertNil(try XCTUnwrap(controller.controllerForTesting(tab: tabs[1])).pinnedTitle)
    }

    func test_launchFocus_landsInItsTabsDrawer_andHoldsOnceTheOtherTabsMount() {
        let controller = makeController()

        controller.openWorkspaceForTesting(threeTabs())

        XCTAssertEqual(controller.activeTabIDForTesting, controller.tabOrderForTesting[1])
        XCTAssertTrue(launchLine(of: controller.focusedSurfaceForTesting).contains("second-right"))
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: deadline) }
        XCTAssertTrue(
            launchLine(of: controller.focusedSurfaceForTesting).contains("second-right"),
            "the third tab's mount must not take the focus back to a pane")
        XCTAssertTrue((controller.focusedSurfaceForTesting as? RecordingSurface)?.isFocused == true)
    }

    func test_aWorktreeOfTheWorkspace_opensTheSameTabs() {
        let controller = makeController()
        let parent = threeTabs()
        let worktreePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wt-\(UUID())")
        let worktree = Worktree(path: worktreePath, branch: "feature", head: "abc1234", isLocked: false)

        controller.openWorkspaceForTesting(
            RepoPickerOverlay.workspace(for: worktree, parent: parent, repoRoot: nil),
            origin: WorktreeOrigin(parent: parent, worktree: worktree))

        assertOpensTheThreeTabsInOrder(controller)
        XCTAssertEqual(controller.tabTitlesForTesting[0], "editor")
        XCTAssertEqual(controller.activeTabIDForTesting, controller.tabOrderForTesting[1])
    }
}
