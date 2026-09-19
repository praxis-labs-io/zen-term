import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SidebarInteractionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controllers: [WindowController] = []
    private var surfaces: [RecordingSurface] = []
    private var interceptors: [KeyInterceptor] = []
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

    private func makeController(initialCWD: URL? = nil) -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: initialCWD)
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

    private func rowFillEdge(in controller: WindowController) throws -> CGFloat {
        let row = try XCTUnwrap(modals(SettingsNavRow.self, in: controller).first, "a workspace row")
        return frame(of: row, in: controller).maxX
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
        XCTAssertEqual(
            frame(of: try tabBar(in: controller), in: controller).minX, SidebarView.width - SidebarView.padding,
            "the bar moves in with the canvas, so the first title keeps its place against the pane")
        XCTAssertEqual(
            frame(of: try pane(in: controller), in: controller).minX,
            try rowFillEdge(in: controller) + Self.paneGap,
            "docked, the panes sit one pane-gap from the sidebar's rows, as from a drawer")
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
            try rowFillEdge(in: controller) + Self.paneGap,
            "docked, the panes sit one pane-gap from the sidebar's rows, as from a drawer")
        XCTAssertEqual(
            frame(of: try tabBar(in: controller), in: controller).minX, SidebarView.width - SidebarView.padding,
            "docking again lands the bar back beside the canvas")
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

        let footer = frame(of: controller.sidebarForTesting.footer, in: controller)
        XCTAssertGreaterThanOrEqual(bar.minX, footer.maxX, "the tab bar starts after the docked sidebar's footer")
        XCTAssertGreaterThan(bar.width, 0, "the tab bar keeps room between the sidebar and the toolbar")
        XCTAssertLessThanOrEqual(bar.maxX, dock.minX)
    }

    func test_collapsedLead_namesTheActiveWorkspace() throws {
        let controller = makeController()
        controller.handle(.toggleSidebar)

        XCTAssertEqual(controller.sidebarForTesting.lead.workspaceNameForTesting, "Workspace 1")
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
        let oneLine = NSTextField(labelWithString: "Home")
        oneLine.font = TabBarView.chipFont
        XCTAssertEqual(
            name.frame.height, oneLine.fittingSize.height, accuracy: 0.5, "a long name truncates instead of wrapping")
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
    }

    func test_focusedRow_showsTheSelectionFill_andArrowsMoveItWithinTheRows() throws {
        let controller = makeController()
        _ = controller.addWorkspaceForTesting(name: "api", folder: root)
        _ = controller.addWorkspaceForTesting(name: "web", folder: root)
        controller.window.makeKeyAndOrderFront(nil)
        let rows = controller.sidebarForTesting.view.rowsForTesting

        controller.sidebarForTesting.focusActiveRow()
        XCTAssertTrue(controller.window.firstResponder === rows[0], "entry lands on the active workspace")
        XCTAssertEqual(rows[0].layer?.backgroundColor, Theme.current.chrome.selectionFill.cgColor)

        for expected in [1, 2, 2] {
            controller.window.sendEvent(key(.down, in: controller))
            XCTAssertTrue(controller.window.firstResponder === rows[expected], "↓ lands on row \(expected)")
        }
        for expected in [1, 0, 0] {
            controller.window.sendEvent(key(.up, in: controller))
            XCTAssertTrue(controller.window.firstResponder === rows[expected], "↑ lands on row \(expected)")
        }
    }

    func test_clickingARow_neverGivesItTheKeyboard() throws {
        let controller = makeController()
        _ = controller.addWorkspaceForTesting(name: "api", folder: root)
        let apiPane = try XCTUnwrap(surfaces.last)
        controller.window.makeKeyAndOrderFront(nil)
        try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface).focus()
        let row = controller.sidebarForTesting.view.rowsForTesting[1]

        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        row.mouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: controller.window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1)))

        XCTAssertTrue(
            controller.window.firstResponder === apiPane.view, "the click switches, and the pane has the keys")
        XCTAssertFalse(row.acceptsFirstResponder, "AppKit would otherwise promote the clicked row itself")
    }

    func test_strayKeys_inTheSidebar_behaveLikeAList() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let recorder = KeyRecorder()
        recorder.nextResponder = controller.window.nextResponder
        controller.window.nextResponder = recorder
        controller.sidebarForTesting.focusActiveRow()
        let row = try XCTUnwrap(controller.sidebarForTesting.view.rowsForTesting.first)

        for (code, text, flags) in [
            (UInt16(48), "\t", NSEvent.ModifierFlags()), (48, "\u{19}", [.shift]),
            (123, "\u{F702}", [.function, .numericPad]), (124, "\u{F703}", [.function, .numericPad]),
        ] {
            controller.window.sendEvent(typed(code, text, flags, in: controller))
            XCTAssertTrue(controller.window.firstResponder === row, "key \(code) leaves focus on the row")
        }
        XCTAssertEqual(recorder.keyCodes, [], "Tab, ⇧Tab, ← and → do nothing")

        controller.window.sendEvent(typed(0, "a", [], in: controller))
        controller.window.sendEvent(typed(49, " ", [], in: controller))
        XCTAssertEqual(recorder.keyCodes, [0, 49], "a letter and Space go unhandled, so AppKit beeps")
    }

    private final class KeyRecorder: NSResponder {
        var keyCodes: [UInt16] = []
        override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
    }

    private func typed(
        _ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags, in controller: WindowController
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: controller.window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    func test_cmdW_fromTheSidebar_closesThePaneItCameFrom_andFocusLandsOnAPane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let left = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        controller.handle(.splitVertical)
        let right = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        controller.sidebarForTesting.focusActiveRow()

        try press("w", [.command], keyCode: 13, in: controller)

        XCTAssertTrue(right.terminated, "⌘W closes the pane the sidebar came from")
        XCTAssertFalse(left.terminated)
        XCTAssertTrue(controller.window.firstResponder === left.view)
    }

    func test_cmdW_fromTheSidebar_onALastPane_landsOnTheNextTabsPane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let first = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        controller.newTabForTesting()
        let second = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        controller.sidebarForTesting.focusActiveRow()

        try press("w", [.command], keyCode: 13, in: controller)

        XCTAssertTrue(second.terminated)
        XCTAssertTrue(controller.window.firstResponder === first.view)
    }

    func test_focusedRowsWorkspaceClosing_returnsFocusToThePane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()
        _ = controller.addWorkspaceForTesting(name: "api", folder: root)
        let background = try XCTUnwrap(surfaces.last)
        try nav(.left, in: controller)
        controller.window.sendEvent(key(.down, in: controller))
        XCTAssertTrue(controller.window.firstResponder === controller.sidebarForTesting.view.rowsForTesting[1])

        background.delegate?.surfaceDidExit(background, code: 0)

        XCTAssertEqual(controller.sidebarForTesting.view.rowsForTesting.count, 1, "the api workspace closed")
        XCTAssertTrue(controller.window.firstResponder === pane.view)
    }

    func test_cmdCtrlW_onTheFocusedRow_closesItsWorkspace_andFocusLandsOnTheNeighboursPane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let api = controller.addWorkspaceForTesting(name: "api", folder: root)
        let apiSurface = try XCTUnwrap(surfaces.last)
        controller.sidebarForTesting.focusActiveRow()
        XCTAssertTrue(controller.sidebarForTesting.hasFocus)

        try press("w", [.command, .control], keyCode: 13, in: controller)

        XCTAssertEqual(controller.activeWorkspaceIDForTesting, api)
        XCTAssertFalse(controller.sidebarForTesting.hasFocus)
        XCTAssertTrue(controller.window.firstResponder === apiSurface.view)
    }

    func test_return_onAFocusedRow_switchesToItsWorkspace_andFocusesItsPane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let api = controller.addWorkspaceForTesting(name: "api", folder: root)
        let apiSurface = try XCTUnwrap(surfaces.last)

        controller.sidebarForTesting.focusActiveRow()
        controller.window.sendEvent(key(.down, in: controller))
        controller.window.sendEvent(key(.return, in: controller))

        XCTAssertEqual(controller.activeWorkspaceIDForTesting, api)
        XCTAssertTrue(controller.window.firstResponder === apiSurface.view)
    }

    func test_return_onTheActiveRow_returnsFocusToItsPane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let home = controller.activeWorkspaceIDForTesting
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        _ = controller.addWorkspaceForTesting(name: "api", folder: root)

        controller.sidebarForTesting.focusActiveRow()
        controller.window.sendEvent(key(.return, in: controller))

        XCTAssertEqual(controller.activeWorkspaceIDForTesting, home)
        XCTAssertTrue(controller.window.firstResponder === pane.view, "↵ on the workspace you're in goes back to it")
    }

    func test_escape_returnsFocusToThePaneItCameFrom() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()

        controller.sidebarForTesting.focusActiveRow()
        XCTAssertTrue(controller.sidebarForTesting.hasFocus)
        controller.window.sendEvent(key(.escape, in: controller))

        XCTAssertFalse(controller.sidebarForTesting.hasFocus)
        XCTAssertTrue(controller.window.firstResponder === pane.view)
    }

    func test_escape_returnsFocusToTheDrawerItCameFrom() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        XCTAssertTrue(controller.window.firstResponder === drawer.view, "opening the drawer focuses it")

        controller.sidebarForTesting.focusActiveRow()
        controller.window.sendEvent(key(.escape, in: controller))

        XCTAssertTrue(controller.window.firstResponder === drawer.view)
    }

    func test_cmdOptLeft_fromTheLeftmostPane_focusesTheSidebar_andCmdOptRightReturns() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()

        try nav(.left, in: controller)
        XCTAssertTrue(controller.window.firstResponder === controller.sidebarForTesting.view.rowsForTesting.first)

        try nav(.right, in: controller)
        XCTAssertTrue(controller.window.firstResponder === pane.view)
    }

    func test_cmdOptLeft_reachesTheSidebarOnlyFromTheLeftColumn_andReturnsToThatPane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let left = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        controller.handle(.splitVertical)
        let right = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        XCTAssertFalse(left === right, "the split focuses the new pane")
        XCTAssertTrue(controller.window.firstResponder === right.view)

        controller.containerForTesting.layoutSubtreeIfNeeded()
        try nav(.left, in: controller)
        XCTAssertTrue(controller.window.firstResponder === left.view, "a pane to the left wins over the sidebar")

        try nav(.left, in: controller)
        XCTAssertTrue(controller.sidebarForTesting.hasFocus)

        try nav(.right, in: controller)
        XCTAssertTrue(controller.window.firstResponder === left.view, "focus goes back to the pane it came from")
    }

    func test_cmdOptLeft_fromTheBottomDrawer_focusesTheSidebar_andCmdOptRightReturnsToIt() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)

        try nav(.left, in: controller)
        XCTAssertTrue(controller.sidebarForTesting.hasFocus)

        try nav(.right, in: controller)
        XCTAssertTrue(controller.window.firstResponder === drawer.view)
    }

    func test_nvimNavigatorFocusLeft_fromTheLeftmostPane_focusesTheSidebar() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()
        let token = try XCTUnwrap(pane.lastConfig?.environment["ZEN_PANE"].flatMap { Int($0) })

        NavRegistry.shared.route(focus: token, .left)

        XCTAssertTrue(controller.sidebarForTesting.hasFocus)
    }

    func test_cmdOptUpDownLeft_fromTheSidebar_sayThereIsNoPane_andKeepFocus() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.sidebarForTesting.focusActiveRow()
        let row = try XCTUnwrap(controller.sidebarForTesting.view.rowsForTesting.first)

        for (direction, word) in [(Direction.up, "up"), (.down, "down"), (.left, "left")] {
            try nav(direction, in: controller)
            XCTAssertTrue(controller.window.firstResponder === row, "⌘⌥ \(word) keeps the row")
            XCTAssertTrue(showsToast("No pane \(word) to focus", in: controller), word)
        }
    }

    func test_nvimNavigatorFocusLeft_fromABackgroundTab_leavesTheSidebarAlone() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let stale = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        let token = try XCTUnwrap(stale.lastConfig?.environment["ZEN_PANE"].flatMap { Int($0) })
        controller.newTabForTesting()
        let current = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        XCTAssertTrue(controller.window.firstResponder === current.view)

        NavRegistry.shared.route(focus: token, .left)

        XCTAssertFalse(controller.sidebarForTesting.hasFocus, "a late command from a tab you left moves nothing")
        XCTAssertTrue(controller.window.firstResponder === current.view)
    }

    func test_cmdOptLeft_withTheSidebarCollapsed_keepsFocus_andSaysThereIsNoPane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.handle(.toggleSidebar)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()

        try nav(.left, in: controller)

        XCTAssertTrue(controller.window.firstResponder === pane.view)
        XCTAssertTrue(showsToast("No pane left to focus\nPress ⌘⌃S to show the sidebar.", in: controller))
    }

    func test_theEdgeToast_namesTheBoundSidebarChord_andOnlyWhileCollapsed() throws {
        rebindSidebarToggle(to: Chord(command: true, shift: true, key: "e"))
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.handle(.toggleSidebar)
        try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface).focus()

        try nav(.left, in: controller)

        let collapsed = "No pane left to focus\nPress ⌘⇧E to show the sidebar."
        XCTAssertTrue(showsToast(collapsed, in: controller), "the hint follows a rebinding")
        for line in collapsed.split(separator: "\n") {
            let width = (String(line) as NSString).size(withAttributes: [.font: ToastView.messageFont]).width
            XCTAssertLessThanOrEqual(
                width, ToastView.messageMaxWidth,
                "wraps at \(Int(width))pt > \(Int(ToastView.messageMaxWidth))pt: \(line)")
        }
    }

    func test_cmdOptLeft_endsScrollMode_soArrowsReachTheRows() throws {
        let controller = makeController()
        _ = controller.addWorkspaceForTesting(name: "api", folder: root)
        controller.window.makeKeyAndOrderFront(nil)
        let keys = interceptor(for: controller)
        controller.handle(.toggleScrollMode)
        XCTAssertNotNil(keys.modeHandler, "scroll mode claims plain keys")

        XCTAssertNil(keys.route(navEvent(.left, [.command, .option], in: controller)))
        let down = key(.down, in: controller)
        XCTAssertTrue(keys.route(down) === down, "↓ passes the interceptor to the row")
        controller.window.sendEvent(down)

        XCTAssertTrue(controller.window.firstResponder === controller.sidebarForTesting.view.rowsForTesting[1])
    }

    func test_ctrlBoundNav_fromTheSidebar_returnsEvenWhenThePaneRunsVim() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()
        let token = try XCTUnwrap(pane.lastConfig?.environment["ZEN_PANE"].flatMap { Int($0) })
        NavRegistry.shared.setVim(token: token, true)
        defer { NavRegistry.shared.setVim(token: token, false) }
        let keys = interceptor(for: controller)
        keys.setKeymap([Chord(control: true, key: "→"): .navRight])
        keys.passThroughGuard = { chord, action in
            NavGuard.shouldPassThrough(
                chord: chord, action: action, focusedPaneIsVim: controller.focusedPaneIsVim,
                toolFloatIsOpen: false)
        }
        XCTAssertTrue(controller.focusedPaneIsVim)

        controller.sidebarForTesting.focusActiveRow()
        XCTAssertNil(keys.route(navEvent(.right, [.control], in: controller)), "the sidebar has no vim to defer to")

        XCTAssertTrue(controller.window.firstResponder === pane.view)
    }

    func test_focusSidebar_isUnboundByDefault_andParsesFromConfig() {
        XCTAssertFalse(KeymapDefaults.map.values.contains(.focusSidebar))
        XCTAssertEqual(KeyInterceptor.ReservedChord(token: "focus_sidebar"), .focusSidebar)
    }

    func test_focusSidebar_boundToAChord_focusesTheActiveRow() throws {
        let controller = makeController()
        _ = controller.addWorkspaceForTesting(name: "api", folder: root)
        controller.window.makeKeyAndOrderFront(nil)
        let keys = interceptor(for: controller)
        keys.setKeymap([Chord(command: true, control: true, key: "e"): .focusSidebar])
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
                windowNumber: controller.window.windowNumber, context: nil, characters: "\u{05}",
                charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))

        XCTAssertNil(keys.route(event))

        XCTAssertTrue(controller.window.firstResponder === controller.sidebarForTesting.view.rowsForTesting.first)
    }

    func test_focusSidebar_whileCollapsed_docksTheSidebar_andFocusesTheActiveRow() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.handle(.toggleSidebar)
        controller.window.setContentSize(controller.window.contentMinSize)
        let narrow = contentWidth(controller)
        try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface).focus()

        controller.handle(.focusSidebar)

        XCTAssertTrue(controller.sidebarForTesting.isDocked)
        XCTAssertEqual(
            controller.window.contentMinSize.width, narrow + SidebarView.width,
            "docking reserves the sidebar's width, as ⌃⌘S does")
        XCTAssertTrue(controller.window.firstResponder === controller.sidebarForTesting.view.rowsForTesting.first)
    }

    func test_focusSidebar_overAToolFloat_isBlockedLikePaneNav_andDoesNotDock() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.handle(.toggleSidebar)
        controller.handle(.toggleToolFloat(ToolFloat.scratch.id))
        waitUntil(controller.floatsForTesting.isOpen, "the scratch float to open")
        let float = try XCTUnwrap(controller.floatsForTesting.shownSurface as? RecordingSurface)

        controller.handle(.focusSidebar)

        XCTAssertFalse(controller.sidebarForTesting.isDocked)
        XCTAssertTrue(controller.window.firstResponder === float.view)
        let content = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(
            descendants(of: content).contains {
                ($0 as? NSTextField)?.stringValue.hasSuffix("is open. Close it to get back to your panes.") == true
            }, "the float explains why, as it does for pane nav")
    }

    func test_ctrlCmdS_docking_leavesFocusInThePane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.handle(.toggleSidebar)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()

        try toggleSidebar(in: controller)

        XCTAssertTrue(controller.sidebarForTesting.isDocked)
        XCTAssertTrue(controller.window.firstResponder === pane.view, "⌃⌘S shows the sidebar, it does not focus it")
    }

    func test_ctrlCmdS_collapsing_withTheSidebarFocused_returnsFocusToThePane() throws {
        Motion.isReduceMotionEnabled = { false }
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()
        controller.sidebarForTesting.focusActiveRow()

        try toggleSidebar(in: controller)

        XCTAssertFalse(controller.sidebarForTesting.isDocked)
        XCTAssertTrue(
            controller.window.firstResponder === pane.view, "focus returns as the slide starts, not when it lands")
    }

    func test_ctrlCmdS_collapsing_fromAPane_leavesFocusInThePane() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        pane.focus()

        try toggleSidebar(in: controller)

        XCTAssertFalse(controller.sidebarForTesting.isDocked, "one press collapses from anywhere, as a drawer does")
        XCTAssertTrue(controller.window.firstResponder === pane.view)
    }

    private func toggleSidebar(in controller: WindowController) throws {
        try press("s", [.command, .control], keyCode: 1, in: controller)
    }

    private func rebindSidebarToggle(to chord: Chord) {
        let original = GeneralConfig.current
        var overridden = original
        var map = KeymapDefaults.map.filter { $0.value != .toggleSidebar }
        map[chord] = .toggleSidebar
        overridden.keymap = map
        GeneralConfig.setCurrentForTesting(overridden)
        addTeardownBlock { GeneralConfig.setCurrentForTesting(original) }
    }

    private func showsToast(_ message: String, in controller: WindowController) -> Bool {
        guard let content = controller.window.contentView else { return false }
        return descendants(of: content).contains { ($0 as? NSTextField)?.stringValue == message }
    }

    private func interceptor(for controller: WindowController) -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { controller.handle($0) }
        controller.keyModeHost = keys
        interceptors.append(keys)
        return keys
    }

    private func nav(_ direction: Direction, in controller: WindowController) throws {
        let keys = interceptor(for: controller)
        XCTAssertNil(keys.route(navEvent(direction, [.command, .option], in: controller)), "⌘⌥ arrows are claimed")
    }

    private func navEvent(
        _ direction: Direction, _ modifiers: NSEvent.ModifierFlags, in controller: WindowController
    ) -> NSEvent {
        let (code, text): (UInt16, String) =
            switch direction {
            case .left: (123, "\u{F702}")
            case .right: (124, "\u{F703}")
            case .up: (126, "\u{F700}")
            case .down: (125, "\u{F701}")
            }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union([.function, .numericPad]),
            timestamp: 0, windowNumber: controller.window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    private enum Key {
        case up, down, `return`, escape

        var code: UInt16 {
            switch self {
            case .up: return 126
            case .down: return 125
            case .return: return 36
            case .escape: return 53
            }
        }

        var text: String {
            switch self {
            case .up: return "\u{F700}"
            case .down: return "\u{F701}"
            case .return: return "\r"
            case .escape: return "\u{1b}"
            }
        }

        var flags: NSEvent.ModifierFlags {
            switch self {
            case .up, .down: return [.function, .numericPad]
            case .return, .escape: return []
            }
        }
    }

    private func key(_ key: Key, in controller: WindowController) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.flags, timestamp: 0,
            windowNumber: controller.window.windowNumber, context: nil, characters: key.text,
            charactersIgnoringModifiers: key.text, isARepeat: false, keyCode: key.code)!
    }

    private func makeCrowdedController() -> WindowController {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        for n in 2...30 { _ = controller.addWorkspaceForTesting(name: "ws \(n)", folder: root) }
        controller.containerForTesting.layoutSubtreeIfNeeded()
        return controller
    }

    private func isOnScreen(_ row: NSView, in scroll: NSScrollView) -> Bool {
        scroll.contentView.documentVisibleRect.contains(row.convert(row.bounds, to: scroll.documentView))
    }

    private func fadedEdges(of view: SidebarView) -> (top: Bool, bottom: Bool) {
        let colors = (view.scrollForTesting.fadeForTesting.colors as? [CGColor]) ?? []
        return (colors.first?.alpha == 0, colors.last?.alpha == 0)
    }

    func test_moreRowsThanFit_theLastIsReachedByDownArrow_andScrolledIntoView() throws {
        let controller = makeCrowdedController()
        let view = controller.sidebarForTesting.view
        let rows = view.rowsForTesting
        let scroll = view.scrollForTesting
        XCTAssertFalse(isOnScreen(try XCTUnwrap(rows.last), in: scroll), "precondition: the list overflows")

        view.focusRow(.workspace(controller.workspaceIDsForTesting[0]))
        for _ in 1..<rows.count { controller.window.sendEvent(key(.down, in: controller)) }

        XCTAssertTrue(controller.window.firstResponder === rows.last, "↓ walks to the last row")
        XCTAssertTrue(isOnScreen(try XCTUnwrap(rows.last), in: scroll), "the focused row is scrolled into view")
    }

    func test_aNewWorkspace_scrollsItsRowIntoView() throws {
        let controller = makeCrowdedController()
        let view = controller.sidebarForTesting.view
        XCTAssertFalse(
            isOnScreen(try XCTUnwrap(view.rowsForTesting.last), in: view.scrollForTesting),
            "precondition: the list overflows and the end is out of sight")

        controller.handle(.newWorkspace)
        controller.containerForTesting.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(view.rowsForTesting.last)
        XCTAssertTrue(isOnScreen(row, in: view.scrollForTesting), "the new workspace's row is on screen")
    }

    private func margins(of row: NSView, in scroll: NSScrollView) -> (above: CGFloat, below: CGFloat) {
        let visible = scroll.contentView.documentVisibleRect
        let frame = row.convert(row.bounds, to: scroll.documentView)
        return (frame.minY - visible.minY, visible.maxY - frame.maxY)
    }

    func test_whileTheSidebarHoldsFocus_noPaneShowsTheHalo() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedPanelForTesting)
        XCTAssertTrue(pane.isFocused, "precondition: the focused pane wears the halo")

        controller.sidebarForTesting.focusActiveRow()
        XCTAssertFalse(pane.isFocused, "the halo answers where the keyboard is")

        controller.window.sendEvent(key(.escape, in: controller))
        XCTAssertTrue(pane.isFocused, "and comes back with focus")
    }

    func test_whileTheWindowIsNotKey_noPaneShowsTheHalo() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedPanelForTesting)
        XCTAssertTrue(pane.isFocused)

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(pane.isFocused, "an unfocused window shows no halo")

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertTrue(pane.isFocused, "and it comes back when the window does")
    }

    func test_theWindowBecomingKeyAgain_leavesTheSidebarsFocusAlone() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let pane = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.sidebarForTesting.focusActiveRow()

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertFalse(pane.isFocused, "the sidebar still holds focus, so the halo stays out")
    }

    func test_aPickerOpenedFromTheSidebar_handsFocusBackToItsRow() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.sidebarForTesting.focusActiveRow()
        let row = try XCTUnwrap(controller.sidebarForTesting.view.rowsForTesting.first)
        XCTAssertTrue(controller.window.firstResponder === row, "precondition: the sidebar holds focus")

        controller.handle(.toggleRepoPicker)
        waitUntil(controller.isModalOverlayOpen, "the picker to open")
        controller.handle(.toggleRepoPicker)

        XCTAssertTrue(controller.window.firstResponder === row, "focus goes back where the picker was opened from")
    }

    func test_aConfirmRaisedFromACardOpenedInTheSidebar_handsFocusBackToItsRow() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.sidebarForTesting.focusActiveRow()
        let row = try XCTUnwrap(controller.sidebarForTesting.view.rowsForTesting.first)

        controller.handle(.toggleRepoPicker)
        waitUntil(controller.isModalOverlayOpen, "the picker to open")
        controller.presentConfirm(
            variant: .warning, title: "Close Workspace", message: "This stops everything running in it.",
            confirmLabel: "Close", onConfirm: {})
        controller.window.sendEvent(key(.escape, in: controller))

        XCTAssertFalse(controller.isConfirmOpen)
        XCTAssertTrue(
            controller.window.firstResponder === row,
            "the card closing is what returns focus, so the confirm has to read it after that")
    }

    func test_aConfirmCancelledFromTheSidebar_handsFocusBackToItsRow() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.sidebarForTesting.focusActiveRow()
        let row = try XCTUnwrap(controller.sidebarForTesting.view.rowsForTesting.first)

        controller.presentConfirm(
            variant: .warning, title: "Close Workspace", message: "This stops everything running in it.",
            confirmLabel: "Close", onConfirm: {})
        XCTAssertTrue(controller.isConfirmOpen)
        controller.window.sendEvent(key(.escape, in: controller))

        XCTAssertFalse(controller.isConfirmOpen)
        XCTAssertTrue(controller.window.firstResponder === row, "a cancelled confirm goes back to the row")
    }

    func test_leavingFillScreen_withTheSidebarDockedSince_keepsTheWindowAtItsMinimum() throws {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        controller.handle(.toggleSidebar)
        XCTAssertFalse(controller.sidebarForTesting.isDocked, "precondition: collapsed, so the minimum is narrow")
        var narrow = controller.window.frame
        narrow.size.width = controller.window.contentMinSize.width
        controller.window.setFrame(narrow, display: true)

        controller.handle(.fillScreen)
        controller.handle(.toggleSidebar)
        let minimum = controller.window.contentMinSize.width
        controller.handle(.fillScreen)

        let restored = controller.window.contentRect(forFrameRect: controller.window.frame)
        XCTAssertGreaterThanOrEqual(
            restored.width, minimum - 0.5, "docking raised the minimum, so the restored frame follows it")
        if let visible = (controller.window.screen ?? NSScreen.main)?.visibleFrame {
            XCTAssertLessThanOrEqual(controller.window.frame.maxX, visible.maxX + 0.5, "and stays on screen")
        }
    }

    func test_theSidebarToggle_worksWithACardOpen_andLeavesItOpen() throws {
        let controller = makeController()
        controller.handle(.openSettings)
        let docked = controller.sidebarForTesting.isDocked

        controller.handle(.toggleSidebar)

        XCTAssertEqual(controller.sidebarForTesting.isDocked, !docked, "nothing blocks the sidebar toggle")
        XCTAssertTrue(controller.isModalOverlayOpen, "the card it was pressed over stays open")
    }

    func test_rowsMovingUnderTheCursor_leaveHoverOnOneRowAtMost() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        _ = controller.addWorkspaceForTesting(name: "api", folder: root)
        let rows = controller.sidebarForTesting.view.rowsForTesting
        for row in rows { row.mouseEntered(with: try mouseMoved(in: controller)) }
        XCTAssertEqual(
            rows.filter { $0.layer?.backgroundColor == Theme.current.chrome.fill(.hover).cgColor }.count, rows.count,
            "precondition: every row is left hovered, as rows sliding under a still cursor leave them")

        controller.handle(.newWorkspace)

        let hovered = controller.sidebarForTesting.view.rowsForTesting
            .filter { $0.layer?.backgroundColor == Theme.current.chrome.fill(.hover).cgColor }
        XCTAssertLessThanOrEqual(hovered.count, 1, "a render re-reads the pointer, so stale hovers clear")
    }

    func test_whileACardCoversTheSidebar_rowsTakeNoHover() throws {
        let controller = makeController()
        controller.window.makeKeyAndOrderFront(nil)
        let row = try XCTUnwrap(controller.sidebarForTesting.view.rowsForTesting.first)

        controller.handle(.openSettings)
        row.mouseEntered(with: try mouseMoved(in: controller))

        XCTAssertNotEqual(
            row.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor,
            "a card covers the sidebar without taking the rows' tracking events")

        controller.handle(.openSettings)
        row.mouseEntered(with: try mouseMoved(in: controller))

        XCTAssertEqual(
            row.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor,
            "hover comes back when the card closes")
    }

    private func mouseMoved(in controller: WindowController) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: controller.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
    }

    func test_theSidebarScroll_takesNoTitlebarInset() throws {
        let controller = makeCrowdedController()
        let scroll = controller.sidebarForTesting.view.scrollForTesting

        XCTAssertFalse(
            scroll.automaticallyAdjustsContentInsets,
            "a full-size-content window otherwise pads the top by the titlebar height")
        XCTAssertEqual(scroll.contentInsets.top, 0)
    }

    func test_aRowScrolledToAnEdge_landsClearOfTheFade() throws {
        let controller = makeCrowdedController()
        let view = controller.sidebarForTesting.view
        let scroll = view.scrollForTesting
        let rows = view.rowsForTesting
        let (first, last) = (0, rows.count - 1)

        view.focusRow(.workspace(controller.workspaceIDsForTesting[first]))
        for _ in 0..<(last - 5) { controller.window.sendEvent(key(.down, in: controller)) }
        let goingDown = try XCTUnwrap(controller.window.firstResponder as? NSView)

        XCTAssertFalse(isOnScreen(try XCTUnwrap(rows.last), in: scroll), "precondition: rows remain below")
        XCTAssertGreaterThanOrEqual(
            margins(of: goingDown, in: scroll).below, FadingScrollView.fadeDepth - 0.5,
            "a row reached going down clears the bottom fade")

        for _ in 0..<(last - 10) { controller.window.sendEvent(key(.up, in: controller)) }
        let goingUp = try XCTUnwrap(controller.window.firstResponder as? NSView)

        XCTAssertFalse(isOnScreen(rows[first], in: scroll), "precondition: rows remain above")
        XCTAssertGreaterThanOrEqual(
            margins(of: goingUp, in: scroll).above, FadingScrollView.fadeDepth - 0.5,
            "a row reached going up clears the top fade")
    }

    func test_theSidebarFadesOnlyTheEdgesContentIsHiddenPast() throws {
        let roomy = makeController()
        roomy.containerForTesting.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            try XCTUnwrap(roomy.sidebarForTesting.view.scrollForTesting.layer).contentsAreFlipped(),
            "the fade's start is the top edge")
        XCTAssertTrue(fadedEdges(of: roomy.sidebarForTesting.view) == (false, false), "nothing overflows")
        roomy.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        let controller = makeCrowdedController()
        let view = controller.sidebarForTesting.view
        view.focusRow(.workspace(controller.workspaceIDsForTesting[0]))
        XCTAssertTrue(fadedEdges(of: view) == (false, true), "at the top, only the bottom edge hides rows")

        for _ in 1..<view.rowsForTesting.count { controller.window.sendEvent(key(.down, in: controller)) }
        XCTAssertTrue(fadedEdges(of: view) == (true, false), "at the end, only the top edge hides rows")
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

    func test_aWindowsFirstRow_showsTheBranchOfTheFolderItStartedIn() throws {
        let repo = try GitFixture.makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        let controller = makeController(initialCWD: repo)

        waitUntil(
            controller.sidebarForTesting.view.rowsForTesting.first?.detailForTesting == "main",
            "the first workspace's branch to come from the folder its shell started in")
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

    func test_rowTooltips_nameTheShortcutForTheirPlaceInTheSidebar() throws {
        let controller = makeController()
        let other = controller.addWorkspaceForTesting(name: "api", folder: root)
        controller.activateWorkspaceForTesting(other)

        let tooltips = controller.sidebarForTesting.view.rowsForTesting.compactMap(\.tooltip)
        XCTAssertEqual(tooltips.map(\.label), ["Switch workspace", "Switch workspace"])
        XCTAssertEqual(tooltips.map(\.shortcutForTesting), ["⌘⌃1", "⌘⌃2"])
    }
}
