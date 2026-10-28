import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowControllerThemeTreeTests: WindowTestCase {
    private var originalTheme: AppTheme!
    private var originalConfig: GeneralConfig!
    private var originalOverride: (() -> TerminalSurface)?
    private var tempRoots: [URL] = []
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalTheme = Theme.current
        originalConfig = GeneralConfig.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        GeneralConfig.setCurrentForTesting(.builtIn)
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        Theme.setCurrentForTesting(originalTheme)
        GeneralConfig.setCurrentForTesting(originalConfig)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private final class CountingProbe: NSView, ThemeReapplying {
        var count = 0
        func reapplyTheme() { count += 1 }
    }

    private final class RebuildingParent: NSView, ThemeReapplying {
        var child = CountingProbe()
        var retired: [CountingProbe] = []
        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(child)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        func reapplyTheme() {
            retired.append(child)
            child.removeFromSuperview()
            child = CountingProbe()
            addSubview(child)
        }
    }

    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-themetree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 1=#ff0000
        palette = 5=#00ff00
        palette = \(AccentSlot.themeDefault.ansiIndex)=#00ffff
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        return controller
    }

    private func post(_ change: ConfigChange?) {
        let info = change.map { [ConfigChange.userInfoKey: $0] }
        NotificationCenter.default.post(name: .configDidChange, object: nil, userInfo: info)
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    private func click(_ row: SettingsNavRow) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: row.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        row.mouseDown(with: event)
    }

    private func fill(_ button: AppButton) -> CGColor? { button.layer?.backgroundColor }

    func test_themeChange_recolorsANestedButtonAndAHiddenArrangedOne() throws {
        let controller = makeController()
        let nested = AppButton(title: "Nested", variant: .primary)
        let hidden = AppButton(title: "Hidden", variant: .primary)
        let inner = NSStackView(views: [nested])
        let outer = NSStackView(views: [inner, hidden])
        hidden.isHidden = true
        controller.window.contentView!.addSubview(outer)
        controller.window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertTrue(outer.subviews.contains(hidden), "premise: a hidden arranged view stays a subview")
        let nestedBefore = fill(nested)
        let hiddenBefore = fill(hidden)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)

        XCTAssertNotEqual(nestedBefore, fill(nested), "a nested button kept the old theme")
        XCTAssertNotEqual(hiddenBefore, fill(hidden), "a hidden arranged button kept the old theme")
    }

    func test_walk_skipsAChildItsParentRebuiltAndCallsASiblingOnce() {
        let root = NSView()
        let parent = RebuildingParent(frame: .zero)
        let sibling = CountingProbe()
        root.addSubview(parent)
        root.addSubview(sibling)
        let firstChild = parent.child

        root.reapplyThemeTree()

        XCTAssertEqual(firstChild.count, 0, "the walk recolored a view its parent had already replaced")
        XCTAssertEqual(parent.child.count, 0, "the walk recolored a view built after the walk began")
        XCTAssertEqual(sibling.count, 1)
    }

    func test_allChange_walksEachSubtreeOnce() throws {
        let controller = makeController()
        let root = controller.window.contentView!
        let hostProbe = CountingProbe()
        let dockProbe = CountingProbe()
        let rootProbe = CountingProbe()
        let host = try XCTUnwrap(descendants(of: root).compactMap { $0 as? PanelHostView }.first)
        let dock = try XCTUnwrap(descendants(of: root).compactMap { $0 as? ToggleDock }.first)
        host.addSubview(hostProbe)
        dock.addSubview(dockProbe)
        root.addSubview(rootProbe)

        post(nil)

        XCTAssertEqual(rootProbe.count, 1)
        XCTAssertEqual(hostProbe.count, 1, "an untagged reload walked the pane host again")
        XCTAssertEqual(dockProbe.count, 1, "an untagged reload walked the dock again")
    }

    private func rebind(_ action: KeyInterceptor.ReservedChord, to chord: Chord) {
        var config = GeneralConfig.current
        config.keymap = config.keymap.filter { $0.value != action }
        config.keymap[chord] = action
        GeneralConfig.setCurrentForTesting(config)
    }

    func test_keymapChange_recolorsNothing() throws {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()
        let root = controller.window.contentView!
        controller.handle(.toggleBottomDrawer)
        controller.handle(.toggleCommandPalette)
        let drawer = try XCTUnwrap(
            descendants(of: root).compactMap { $0 as? PanelHostView }
                .first { $0.builtHeaderKeycapForTesting != nil },
            "premise: the drawer's header is mounted")
        let palette = try XCTUnwrap(descendants(of: root).compactMap { $0 as? CommandPaletteOverlay }.first)
        let rootProbe = CountingProbe()
        let drawerProbe = CountingProbe()
        let paletteProbe = CountingProbe()
        root.addSubview(rootProbe)
        drawer.addSubview(drawerProbe)
        palette.addSubview(paletteProbe)
        let borderBefore = drawer.borderForTesting.color

        let rebound = Chord(command: true, shift: true, option: true, control: true, key: "j")
        rebind(.toggleZoom, to: rebound)
        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.keymap)

        XCTAssertEqual(drawer.builtHeaderKeycapForTesting, rebound.displayGlyph, "premise: the rebind landed")
        XCTAssertEqual(rootProbe.count, 0, "a keymap change walked the window")
        XCTAssertEqual(drawerProbe.count, 0, "a keymap change walked the drawer host")
        XCTAssertEqual(paletteProbe.count, 0, "a keymap change walked the open palette")
        XCTAssertEqual(borderBefore, drawer.borderForTesting.color, "a keymap change recolored the drawer")
    }

    func test_themeChange_reachesAnInactiveTabsHostBeforeYouSwitchBack() throws {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()
        let host = try XCTUnwrap(
            descendants(of: controller.window.contentView!).compactMap { $0 as? PanelHostView }.first)
        let before = try XCTUnwrap(host.borderForTesting.color)

        controller.handle(.newTab)
        XCTAssertNil(host.window, "premise: the first tab's host left the window")
        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)
        controller.handle(.selectTab(1))

        XCTAssertNotNil(host.window)
        XCTAssertNotEqual(before, host.borderForTesting.color, "the inactive tab came back in the old theme")
    }

    func test_themeChange_reachesACarryStatusThatWasOutOfTheViewWhenItFired() throws {
        let controller = makeController()
        let picker = CarryPicker()
        picker.settle = 0
        picker.probe = { _, _ in
            IgnoredCatalog(entries: ["node_modules"], resting: [], fileCounts: [:], directories: [])
        }
        picker.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        controller.window.contentView!.addSubview(picker)
        let before = try XCTUnwrap(picker.statusBorderForTesting)

        let listed = expectation(description: "list shown")
        picker.onChanged = { listed.fulfill() }
        picker.workspaceFolder = FileManager.default.temporaryDirectory
        wait(for: [listed], timeout: 5)
        picker.onChanged = nil
        XCTAssertNil(picker.statusForTesting, "premise: the list replaced the status")

        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)
        picker.workspaceFolder = nil

        XCTAssertEqual(picker.statusForTesting, "Choose a folder first.")
        XCTAssertNotEqual(before, picker.statusBorderForTesting, "the returning status kept the old theme")
    }

    func test_themeChange_reachesADrawerRailThatSwappedBackIn() throws {
        let controller = makeController()
        let drawing = WorkspaceTabDrawing()
        controller.window.contentView!.addSubview(drawing)
        drawing.frame = NSRect(x: 0, y: 0, width: 600, height: WorkspaceTabDrawing.height)
        drawing.render(tab: Workspace.Tab(main: "vim", bottom: "tail -f log"), index: 0, opensFocusedIn: nil)
        drawing.layoutSubtreeIfNeeded()
        let rail = try XCTUnwrap(drawing.rail(.bottom))
        XCTAssertNil(rail.superview, "premise: an open drawer has no rail in the view")
        let before = try XCTUnwrap(rail.borderStrokeForTesting)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)
        drawing.render(tab: Workspace.Tab(main: "vim"), index: 0, opensFocusedIn: nil)
        drawing.layoutSubtreeIfNeeded()

        XCTAssertNotNil(rail.superview)
        XCTAssertNotEqual(before, rail.borderStrokeForTesting, "the returning rail kept the old theme")
    }

    func test_themeChange_reachesASettingsResetButtonAfterTheSectionSwitchesBack() throws {
        let controller = makeController()
        let keybinds = SettingsKeybindsSection(capturer: nil)
        let overlay = SettingsOverlay(
            sections: [keybinds, SettingsToolsSection()], capturer: nil, onClose: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        controller.window.contentView!.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
        let navRows = descendants(of: overlay).compactMap { $0 as? SettingsNavRow }
        let before = try XCTUnwrap((keybinds.detailStops().last as? AppButton)?.layer?.backgroundColor)

        click(navRows[1])
        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)
        click(navRows[0])

        let after = try XCTUnwrap((keybinds.detailStops().last as? AppButton)?.layer?.backgroundColor)
        XCTAssertNotEqual(before, after, "the section's reset button came back in the old theme")
    }

    func test_themeChange_recolorsAPresentedUpdateCard() throws {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()
        let card = UpdateCardView(
            state: .available(version: "9.9.9", current: "1.0.0", notes: [], notesURL: nil),
            actions: UpdateCardView.Actions())
        controller.presentUpdateCard(card)
        XCTAssertNotNil(card.window, "premise: the card is in the window")
        let before = card.badgeFillForTesting

        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)

        XCTAssertNotEqual(before, card.badgeFillForTesting, "the presented update card kept the old theme")
    }

    func test_themeChange_reachesAnUpdateProgressBarThatWasOutOfTheCardWhenItFired() throws {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()
        let card = UpdateCardView(state: .downloading(fraction: 0.5), actions: UpdateCardView.Actions())
        controller.presentUpdateCard(card)
        let bar = card.progressBarForTesting
        let before = try XCTUnwrap(bar.fillForTesting)

        card.update(to: .ready(version: "9.9.9"), actions: UpdateCardView.Actions())
        XCTAssertNil(bar.superview, "premise: the finished download left the bar out of the card")
        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)
        card.update(to: .downloading(fraction: 0.1), actions: UpdateCardView.Actions())

        XCTAssertNotNil(bar.superview)
        XCTAssertNotEqual(before, bar.fillForTesting, "the returning progress bar kept the old theme")
    }

    func test_themeChange_recolorsAnOrdinaryToastOnScreen() throws {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()
        controller.showToast(ToastContent(variant: .destructive, title: "Heads up", message: "Something."))
        let toast = try XCTUnwrap(
            descendants(of: controller.window.contentView!).compactMap { $0 as? ToastView }.first)
        let before = toast.badgeFillForTesting

        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)

        XCTAssertNotEqual(before, toast.badgeFillForTesting, "a toast on screen kept the old theme")
    }
}
