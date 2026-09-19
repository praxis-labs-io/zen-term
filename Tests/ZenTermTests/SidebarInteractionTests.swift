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

    private func click(_ row: SettingsNavRow) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        row.mouseDown(with: event)
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

    func test_toggle_collapses_andDocksAgain() throws {
        let controller = makeController()
        let sidebar = controller.sidebarForTesting

        try click(sidebar.toggleButtonForTesting)

        XCTAssertFalse(sidebar.isDocked)
        XCTAssertTrue(sidebar.view.isHidden, "collapsed, the palette and Settings buttons go with the sidebar")
        XCTAssertFalse(sidebar.toggleButtonForTesting.isHidden, "the toggle stays")
        XCTAssertFalse(sidebar.lead.isHidden)
        XCTAssertEqual(frame(of: try pane(in: controller), in: controller).minX, Self.gutter)
        XCTAssertEqual(
            frame(of: try tabBar(in: controller), in: controller).minX + TabBarView.titleInset,
            frame(of: sidebar.lead, in: controller).maxX + CollapsedSidebarLead.dividerGap,
            "the toggle and workspace name lead the tab bar, the divider one gap from the first title")
        XCTAssertGreaterThan(frame(of: sidebar.lead, in: controller).width, 0)

        try click(sidebar.toggleButtonForTesting)

        XCTAssertTrue(sidebar.isDocked)
        XCTAssertFalse(sidebar.view.isHidden)
        XCTAssertTrue(sidebar.lead.isHidden)
        XCTAssertEqual(
            frame(of: try pane(in: controller), in: controller).minX,
            SidebarView.width + Self.paneGap, "docked, the panes sit one pane-gap from the sidebar, as from a drawer")
    }

    func test_toggle_holdsItsWindowPosition_dockedAndCollapsed() throws {
        let controller = makeController()
        let sidebar = controller.sidebarForTesting
        let docked = frame(of: sidebar.toggleButtonForTesting, in: controller)

        try click(sidebar.toggleButtonForTesting)
        let collapsed = frame(of: sidebar.toggleButtonForTesting, in: controller)

        XCTAssertEqual(docked, collapsed, "the toggle never moves between docked and collapsed")
        XCTAssertFalse(sidebar.toggleButtonForTesting.isHidden)
    }

    private func contentWidth(_ controller: WindowController) -> CGFloat {
        controller.window.contentRect(forFrameRect: controller.window.frame).width
    }

    func test_docking_growsAWindowNarrowerThanTheDockedMinimum() throws {
        let controller = makeController()
        controller.handle(.toggleSidebar)
        controller.window.setContentSize(controller.window.contentMinSize)
        let narrow = contentWidth(controller)

        controller.handle(.toggleSidebar)

        XCTAssertGreaterThanOrEqual(contentWidth(controller), narrow + SidebarView.width)
        XCTAssertEqual(controller.window.contentMinSize.width, narrow + SidebarView.width)
    }

    func test_collapsing_lowersTheMinimumAgain() throws {
        let controller = makeController()
        let docked = controller.window.contentMinSize.width

        controller.handle(.toggleSidebar)

        XCTAssertEqual(controller.window.contentMinSize.width, docked - SidebarView.width)
    }

    func test_dockedAtTheMinimumWidth_withAUserFloat_theTabBarKeepsRoom() throws {
        var config = GeneralConfig.current
        config.floats = [
            ToolFloat(
                id: "dev", order: 0, title: "dev", icon: "square.on.square", command: "cmd", dir: nil,
                widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
                persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "d"))
        ]
        GeneralConfig.setCurrentForTesting(config)
        let controller = makeController()
        controller.window.setContentSize(controller.window.contentMinSize)

        let bar = frame(of: try tabBar(in: controller), in: controller)
        let dock = frame(of: controller.dockForTesting, in: controller)

        XCTAssertGreaterThanOrEqual(bar.minX, SidebarView.width, "the tab bar starts after the docked sidebar")
        XCTAssertGreaterThan(bar.width, 0, "the tab bar keeps room between the sidebar and the toolbar")
        XCTAssertLessThanOrEqual(bar.maxX, dock.minX)
    }

    func test_collapsedLead_namesTheActiveWorkspace() throws {
        let controller = makeController()
        controller.handle(.toggleSidebar)

        XCTAssertEqual(controller.sidebarForTesting.lead.workspaceNameForTesting, "Home")
    }

    func test_collapsedLead_truncatesALongWorkspaceNameAtATabTitlesWidth() throws {
        let controller = makeController()
        let long = controller.addWorkspaceForTesting(name: String(repeating: "workspace-", count: 20), folder: root)
        controller.activateWorkspaceForTesting(long)

        controller.handle(.toggleSidebar)

        controller.containerForTesting.layoutSubtreeIfNeeded()
        let name = controller.sidebarForTesting.lead.workspaceNameLabelForTesting
        XCTAssertLessThanOrEqual(
            name.alignmentRect(forFrame: name.frame).width, TabBarView.maxChipWidth,
            "a long name truncates instead of pushing the tabs off the bar")
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

    private func press(
        _ key: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, in controller: WindowController
    ) throws {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { controller.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                keyCode: keyCode))
        XCTAssertNil(keys.route(event), "the shortcut is claimed, not passed to the pane")
    }

    private func hiding(_ buttons: Set<ToolbarButton>) {
        var config = GeneralConfig.current
        config.hiddenToolbarButtons = buttons
        GeneralConfig.setCurrentForTesting(config)
    }

    func test_hidingCommandPalette_hidesItsFooterButton_andItsShortcutStillWorks() throws {
        hiding([.commandPalette])
        let controller = makeController()

        XCTAssertTrue(controller.sidebarForTesting.footer.paletteButtonForTesting.isHidden)
        XCTAssertFalse(controller.sidebarForTesting.footer.settingsButtonForTesting.isHidden)
        try press("p", [.command, .shift], keyCode: 35, in: controller)
        XCTAssertEqual(modals(CommandPaletteOverlay.self, in: controller).count, 1)
    }

    func test_hidingSettings_hidesItsFooterButton_andItsShortcutStillWorks() throws {
        hiding([.settings])
        let controller = makeController()

        XCTAssertTrue(controller.sidebarForTesting.footer.settingsButtonForTesting.isHidden)
        XCTAssertFalse(controller.sidebarForTesting.footer.paletteButtonForTesting.isHidden)
        try press(",", [.command], keyCode: 43, in: controller)
        XCTAssertEqual(modals(SettingsOverlay.self, in: controller).count, 1)
    }

    func test_footerPaletteButton_opensTheCommandPalette() throws {
        let controller = makeController()

        try click(controller.sidebarForTesting.footer.paletteButtonForTesting)

        XCTAssertEqual(modals(CommandPaletteOverlay.self, in: controller).count, 1)
        XCTAssertTrue(controller.sidebarForTesting.footer.paletteButtonForTesting.isActive)
    }

    func test_footerSettingsButton_opensSettings() throws {
        let controller = makeController()

        try click(controller.sidebarForTesting.footer.settingsButtonForTesting)

        XCTAssertEqual(modals(SettingsOverlay.self, in: controller).count, 1)
        XCTAssertTrue(controller.sidebarForTesting.footer.settingsButtonForTesting.isActive)
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

    func test_clickingARow_switchesToItsWorkspace_andFocusesItsPane() throws {
        let controller = makeController()
        let home = controller.activeWorkspaceIDForTesting
        let homeSurface = try XCTUnwrap(surfaces.first)
        let other = controller.addWorkspaceForTesting(name: "api", folder: root)
        let otherSurface = try XCTUnwrap(surfaces.last)
        controller.activateWorkspaceForTesting(home)
        let focusesBefore = otherSurface.focusCount

        try click(controller.sidebarForTesting.view.rowsForTesting[1])

        XCTAssertEqual(controller.activeWorkspaceIDForTesting, other)
        XCTAssertGreaterThan(otherSurface.focusCount, focusesBefore, "focus lands in the new workspace's pane")
        XCTAssertFalse(homeSurface.terminated, "the workspace left behind keeps running")

        try click(controller.sidebarForTesting.view.rowsForTesting[0])

        XCTAssertEqual(controller.activeWorkspaceIDForTesting, home)
        XCTAssertTrue(try XCTUnwrap(surfaces.first) === homeSurface)
        XCTAssertEqual(homeSurface.startCount, 1, "the same process, not a restart")
    }

    func test_clickingTheActiveRow_keepsTheWorkspace_andReturnsFocusToItsPane() throws {
        let controller = makeController()
        let home = controller.activeWorkspaceIDForTesting
        let homeSurface = try XCTUnwrap(surfaces.first)
        _ = controller.addWorkspaceForTesting(name: "api", folder: root)
        controller.activateWorkspaceForTesting(home)
        let focusesBefore = homeSurface.focusCount

        try click(controller.sidebarForTesting.view.rowsForTesting[0])

        XCTAssertEqual(controller.activeWorkspaceIDForTesting, home)
        XCTAssertGreaterThan(homeSurface.focusCount, focusesBefore, "a clicked row never keeps the keyboard")
    }

    func test_addButton_opensTheWorkspacePicker() throws {
        ConfigLoader.defaultRootOverrideForTesting = root
        defer { ConfigLoader.defaultRootOverrideForTesting = nil }
        let controller = makeController()

        try click(controller.sidebarForTesting.view.addButtonForTesting)

        waitUntil(!modals(RepoPickerOverlay.self, in: controller).isEmpty, "the workspace picker to open")
    }
}
