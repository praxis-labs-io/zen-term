import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SidebarInteractionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controllers: [WindowController] = []
    private var surfaces: [RecordingSurface] = []
    private var root: URL!
    private var originalConfig: GeneralConfig!

    private static let gutter: CGFloat = 20
    private static let paneGap: CGFloat = 6

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfig = GeneralConfig.current
        var config = GeneralConfig.builtIn
        config.windowGutter = Self.gutter
        config.panelGap = Self.paneGap
        GeneralConfig.setCurrentForTesting(config)
        Motion.isReduceMotionEnabled = { true }
        SidebarController.resetLastChoiceForTesting()
        GitRepoStatus.resetForTesting()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.surfaces.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        SidebarController.resetLastChoiceForTesting()
        GitRepoStatus.resetForTesting()
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(controller)
        controller.mountAndStart()
        return controller
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func frame(of view: NSView, in controller: WindowController) -> NSRect {
        controller.containerForTesting.layoutSubtreeIfNeeded()
        return view.convert(view.bounds, to: controller.containerForTesting)
    }

    private func tabBar(in controller: WindowController) throws -> TabBarView {
        try XCTUnwrap(descendants(of: controller.containerForTesting).compactMap { $0 as? TabBarView }.first)
    }

    private func pane(in controller: WindowController) throws -> PanelHostView {
        try XCTUnwrap(controller.focusedPanelForTesting)
    }

    private func click(_ button: IconButton) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: button.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        button.mouseDown(with: event)
    }

    private func modals<T: NSView>(_ type: T.Type, in controller: WindowController) -> [T] {
        descendants(of: controller.containerForTesting).compactMap { $0 as? T }
    }

    func test_docked_panesAndTabBarStartAfterTheSidebar() throws {
        let controller = makeController()
        let sidebar = controller.sidebarForTesting

        XCTAssertTrue(sidebar.isDocked)
        XCTAssertFalse(sidebar.view.isHidden)
        XCTAssertTrue(sidebar.lead.isHidden)
        XCTAssertEqual(frame(of: try tabBar(in: controller), in: controller).minX, SidebarView.width)
        XCTAssertEqual(
            frame(of: try pane(in: controller), in: controller).minX,
            SidebarView.width + Self.paneGap, "docked, the panes sit one pane-gap from the sidebar, as from a drawer")
    }

    func test_footerToggle_collapses_andTheLeadToggleDocksAgain() throws {
        let controller = makeController()
        let sidebar = controller.sidebarForTesting

        try click(sidebar.view.toggleButtonForTesting)

        XCTAssertFalse(sidebar.isDocked)
        XCTAssertTrue(sidebar.view.isHidden, "collapsed, the palette and Settings buttons go with the sidebar")
        XCTAssertFalse(sidebar.lead.isHidden)
        XCTAssertEqual(frame(of: try pane(in: controller), in: controller).minX, Self.gutter)
        XCTAssertEqual(
            frame(of: try tabBar(in: controller), in: controller).minX,
            frame(of: sidebar.lead, in: controller).maxX, "the toggle and workspace name lead the tab bar")
        XCTAssertGreaterThan(frame(of: sidebar.lead, in: controller).width, 0)

        try click(sidebar.lead.toggleButtonForTesting)

        XCTAssertTrue(sidebar.isDocked)
        XCTAssertFalse(sidebar.view.isHidden)
        XCTAssertTrue(sidebar.lead.isHidden)
        XCTAssertEqual(
            frame(of: try pane(in: controller), in: controller).minX,
            SidebarView.width + Self.paneGap, "docked, the panes sit one pane-gap from the sidebar, as from a drawer")
    }

    func test_collapsedLead_namesTheActiveWorkspace() throws {
        let controller = makeController()
        controller.handle(.toggleSidebar)

        XCTAssertEqual(controller.sidebarForTesting.lead.workspaceNameForTesting, "Home")
    }

    func test_ctrlCmdS_throughTheInterceptor_togglesTheSidebar() throws {
        let controller = makeController()
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { controller.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{13}", charactersIgnoringModifiers: "s",
                isARepeat: false, keyCode: 1))

        XCTAssertNil(keys.route(event), "⌃⌘S is claimed, not passed to the pane")
        XCTAssertFalse(controller.sidebarForTesting.isDocked)

        XCTAssertNil(keys.route(event))
        XCTAssertTrue(controller.sidebarForTesting.isDocked)
    }

    func test_footerPaletteButton_opensTheCommandPalette() throws {
        let controller = makeController()

        try click(controller.sidebarForTesting.view.paletteButtonForTesting)

        XCTAssertEqual(modals(CommandPaletteOverlay.self, in: controller).count, 1)
        XCTAssertTrue(controller.sidebarForTesting.view.paletteButtonForTesting.isActive)
    }

    func test_footerSettingsButton_opensSettings() throws {
        let controller = makeController()

        try click(controller.sidebarForTesting.view.settingsButtonForTesting)

        XCTAssertEqual(modals(SettingsOverlay.self, in: controller).count, 1)
        XCTAssertTrue(controller.sidebarForTesting.view.settingsButtonForTesting.isActive)
    }

    func test_toolbar_noLongerCarriesThePaletteButton() throws {
        let controller = makeController()

        XCTAssertFalse(controller.dockForTesting.visibleLayoutForTesting.contains("Command palette"))
    }

    func test_newWindow_opensTheWayTheLastToggleLeftOne() throws {
        let first = makeController()
        first.handle(.toggleSidebar)

        let second = makeController()

        XCTAssertFalse(second.sidebarForTesting.isDocked)
        XCTAssertFalse(second.sidebarForTesting.lead.isHidden)
        XCTAssertEqual(frame(of: try pane(in: second), in: second).minX, Self.gutter)
    }

    func test_rows_listTheWindowsWorkspaces_andMarkTheActiveOne() throws {
        let controller = makeController()
        let other = controller.addWorkspaceForTesting(name: "api", folder: root)
        controller.activateWorkspaceForTesting(other)

        let rows = controller.sidebarForTesting.view.rowsForTesting
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertEqual(rows[1].layer?.backgroundColor, Theme.current.chrome.fill(.rest).cgColor)
        XCTAssertFalse(rows.contains { $0.acceptsFirstResponder }, "a row click leaves focus in the pane")
    }

    func test_row_showsItsWorkspaceBranch() throws {
        let repo = try GitFixture.makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let controller = makeController()
        let id = controller.addWorkspaceForTesting(name: "repo", folder: repo)
        controller.activateWorkspaceForTesting(id)

        waitUntil(
            controller.sidebarForTesting.view.rowsForTesting.last?.detailForTesting == "main",
            "the branch to land once it is read off the main thread")
    }

    func test_slide_holdsAnOpenFloatsGridToo() throws {
        Motion.isReduceMotionEnabled = { false }
        let controller = makeController()
        controller.handle(.toggleToolFloat(ToolFloat.scratch.id))
        waitUntil(controller.floatsForTesting.isOpen, "the scratch float to open")
        let floatSurface = try XCTUnwrap(controller.floatsForTesting.shownSurface as? RecordingSurface)

        controller.handle(.toggleSidebar)

        XCTAssertEqual(floatSurface.sizeSyncHolds, 1, "the float's edge moves with the canvas, so its grid is held")
        waitUntil(floatSurface.sizeSyncHolds == 0, "the float's hold to release once the slide lands")
    }

    func test_slide_holdsThePaneGridUntilItLands() throws {
        Motion.isReduceMotionEnabled = { false }
        let controller = makeController()
        let paneSurface = try XCTUnwrap(surfaces.first)

        controller.handle(.toggleSidebar)

        XCTAssertEqual(paneSurface.sizeSyncHolds, 1, "the pane's grid is held while the sidebar slides")
        waitUntil(paneSurface.sizeSyncHolds == 0, "the hold to release once the slide lands")
        waitUntil(controller.sidebarForTesting.view.isHidden, "the collapsed sidebar to leave once it lands")
    }
}
