import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowControllerConfigFanOutTests: WindowTestCase {
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
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        secondController?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        secondController = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        Theme.setCurrentForTesting(originalTheme)
        GeneralConfig.setCurrentForTesting(originalConfig)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-fanout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 1=#ff0000
        palette = 5=#00ff00
        # The accent slot, named from the constant rather than pinned: this fixture used to
        # move palette 5 because that was the accent, and went blind when the default moved.
        palette = \(AccentSlot.themeDefault.ansiIndex)=#00ffff
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func test_configDidChange_recolorsPersistentChromeThroughTheFanOut() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        let root = controller.window.contentView!

        guard let tabBar = descendants(of: root).compactMap({ $0 as? TabBarView }).first else {
            return XCTFail("expected the tab bar mounted in the window")
        }
        let accentBefore = tabBar.tracerColorForTesting
        XCTAssertNotNil(accentBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        NotificationCenter.default.post(name: .configDidChange, object: nil)

        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertNotEqual(accentBefore, tabBar.tracerColorForTesting)
    }

    func test_toolbarButtonsChange_hidesTheButtonThroughTheFanOut() throws {
        GeneralConfig.setCurrentForTesting(.builtIn)
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        let dock = try XCTUnwrap(
            descendants(of: controller.window.contentView!).compactMap { $0 as? ToggleDock }.first,
            "expected the footer toolbar mounted in the window")
        XCTAssertTrue(dock.visibleLayoutForTesting.contains("Focus mode"))

        var config = GeneralConfig.builtIn
        config.hiddenToolbarButtons = [.focusMode]
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.toolbarButtons])
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertFalse(dock.visibleLayoutForTesting.contains("Focus mode"))
    }

    func test_configDidChange_appliesWindowChromeThroughTheFanOut() throws {
        var config = GeneralConfig.builtIn
        config.windowChrome = true
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        XCTAssertEqual(controller.window.standardWindowButton(.closeButton)?.isHidden, false)

        config.windowChrome = false
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(name: .configDidChange, object: nil)

        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertEqual(controller.window.standardWindowButton(.closeButton)?.isHidden, true)
    }

    private func post(_ change: ConfigChange) {
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: change])
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func test_keymapOnlyChange_skipsTheChromeRecolor() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller

        guard
            let tabBar = descendants(of: controller.window.contentView!)
                .compactMap({ $0 as? TabBarView }).first
        else {
            return XCTFail("expected the tab bar mounted in the window")
        }
        let accentBefore = tabBar.tracerColorForTesting
        XCTAssertNotNil(accentBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.keymap)

        XCTAssertEqual(
            accentBefore, tabBar.tracerColorForTesting,
            "a keymap-only change re-themed the tab bar — the gate isn't holding")
    }

    func test_themeChange_stillRecolorsThroughTheGate() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller

        guard
            let tabBar = descendants(of: controller.window.contentView!)
                .compactMap({ $0 as? TabBarView }).first
        else {
            return XCTFail("expected the tab bar mounted in the window")
        }
        let accentBefore = tabBar.tracerColorForTesting

        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)

        XCTAssertNotEqual(accentBefore, tabBar.tracerColorForTesting)
    }

    func test_keymapChange_rebuildsThePanelHeaderKeycap() throws {
        var config = GeneralConfig.builtIn
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        controller.handle(.toggleBottomDrawer)
        let opened = expectation(description: "drawer opened")
        OperationQueue.main.addOperation { opened.fulfill() }
        wait(for: [opened], timeout: 5)

        guard
            let header = descendants(of: controller.window.contentView!)
                .compactMap({ ($0 as? PanelHostView)?.builtHeaderKeycapForTesting }).first
        else {
            return XCTFail("expected a drawer panel header mounted in the window")
        }

        let rebound = Chord(command: true, shift: true, option: true, control: true, key: "j")
        config.keymap = config.keymap.filter { $0.value != .toggleZoom }
        config.keymap[rebound] = .toggleZoom
        GeneralConfig.setCurrentForTesting(config)
        post(.keymap)

        let after = descendants(of: controller.window.contentView!)
            .compactMap { ($0 as? PanelHostView)?.builtHeaderKeycapForTesting }.first
        XCTAssertNotEqual(header, after, "the rebind never reached the drawer header keycap")
        XCTAssertEqual(after, rebound.displayGlyph)
    }

    func test_dismissConfigDiagnosticsToast_takesTheNoticeOffScreen() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()

        controller.showConfigDiagnosticsToast(
            ToastContent(variant: .warning, title: "1 problem in your config", message: "a line"),
            landingScope: .keybindLine)
        func mountedToasts() -> [ToastView] {
            descendants(of: controller.window.contentView!).compactMap { $0 as? ToastView }
        }
        XCTAssertEqual(mountedToasts().count, 1, "expected the problem notice mounted")

        Motion.isReduceMotionEnabled = { true }
        controller.dismissConfigDiagnosticsToast()
        let settled = expectation(description: "dismissal settled")
        OperationQueue.main.addOperation { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(mountedToasts().isEmpty, "the notice is still on screen after being retracted")

        controller.dismissConfigDiagnosticsToast()
    }

    private var secondController: WindowController?

    private func makeWindow() -> WindowController {
        WindowController(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), initialCWD: nil)
    }

    private func noticeTitles(in controller: WindowController) -> [String] {
        descendants(of: controller.window.contentView!)
            .compactMap { $0 as? ToastView }
            .flatMap { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
    }

    private func settle() {
        let settled = expectation(description: "settled")
        OperationQueue.main.addOperation { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }

    func test_deliveringToAnotherWindow_sweepsTheNoticeOutOfTheFirst() throws {
        let first = makeWindow()
        controller = first
        let second = makeWindow()
        secondController = second
        first.mountAndStart()
        second.mountAndStart()
        Motion.isReduceMotionEnabled = { true }

        let windows = [first, second]
        XCTAssertTrue(
            WindowController.deliverConfigDiagnosticsNotice(
                ToastContent(variant: .warning, title: "1 problem in your config", message: "a"),
                landingScope: .keybindLine, to: first, replacingAcross: windows))
        settle()
        XCTAssertTrue(noticeTitles(in: first).contains("1 problem in your config"))

        XCTAssertTrue(
            WindowController.deliverConfigDiagnosticsNotice(
                ToastContent(variant: .warning, title: "2 problems in your config", message: "b"),
                landingScope: .keybindLine, to: second, replacingAcross: windows))
        settle()

        XCTAssertTrue(noticeTitles(in: second).contains("2 problems in your config"))
        XCTAssertFalse(
            noticeTitles(in: first).contains("1 problem in your config"),
            "the superseded notice is still up in the other window: \(noticeTitles(in: first))")
    }

    func test_deliveringWithNoKeyWindow_leavesTheExistingNoticeUp() throws {
        let first = makeWindow()
        controller = first
        first.mountAndStart()
        Motion.isReduceMotionEnabled = { true }

        XCTAssertTrue(
            WindowController.deliverConfigDiagnosticsNotice(
                ToastContent(variant: .warning, title: "1 problem in your config", message: "a"),
                landingScope: .keybindLine, to: first, replacingAcross: [first]))
        settle()

        XCTAssertFalse(
            WindowController.deliverConfigDiagnosticsNotice(
                ToastContent(variant: .warning, title: "2 problems in your config", message: "b"),
                landingScope: .keybindLine, to: nil, replacingAcross: [first]))
        settle()

        XCTAssertTrue(
            noticeTitles(in: first).contains("1 problem in your config"),
            "an undeliverable replacement swept the notice: the config is broken and nothing says so")
    }

    func test_floatAdded_reachesAnOpenPaletteInAnotherWindow() throws {
        var config = GeneralConfig.builtIn
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        controller.handle(.toggleCommandPalette)

        func paletteTitles() -> [String] {
            descendants(of: controller.window.contentView!)
                .compactMap { $0 as? CommandPaletteOverlay }
                .flatMap { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
        }
        XCTAssertFalse(paletteTitles().contains("Notes"), "the float doesn't exist yet")

        config.floats = [
            ToolFloat(
                id: "notes", order: 0, title: "Notes", icon: ToolFloatParser.defaultIcon,
                command: "ls", dir: nil, widthFraction: 0.85, heightFraction: 0.85,
                requiresGitRepo: false, persist: .ephemeral,
                toggle: Chord(command: true, shift: true, key: "n"))
        ]
        GeneralConfig.setCurrentForTesting(config)
        post(.floats)

        XCTAssertTrue(
            paletteTitles().contains("Notes"),
            "a float added while the palette is open never reached it: \(paletteTitles())")
    }

    func test_keymapChange_reresolvesAnOpenPalettesShortcutColumn() throws {
        var config = GeneralConfig.builtIn
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        controller.handle(.toggleCommandPalette)

        func paletteKeycaps() throws -> [String] {
            let palette = descendants(of: controller.window.contentView!)
                .compactMap { $0 as? CommandPaletteOverlay }.first
            return try XCTUnwrap(palette, "expected the palette mounted").builtRowShortcutsForTesting
        }
        XCTAssertTrue(try paletteKeycaps().contains("⌘⇧⏎"), "expected Focus Mode's default chord on a row")

        let rebound = Chord(command: true, shift: true, option: true, control: true, key: "j")
        config.keymap = config.keymap.filter { $0.value != .toggleZoom }
        config.keymap[rebound] = .toggleZoom
        GeneralConfig.setCurrentForTesting(config)
        post(.keymap)

        let after = try paletteKeycaps()
        XCTAssertFalse(after.contains("⌘⇧⏎"), "the palette is still offering the chord that moved")
        XCTAssertTrue(
            after.contains(rebound.displayGlyph),
            "the rebind never reached the open palette's shortcut column")
    }
}
