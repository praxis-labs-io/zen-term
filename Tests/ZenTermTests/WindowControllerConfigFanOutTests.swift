import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Integration test for the `.configDidChange` reapply fan-out in `WindowController` (ZEN-102).
///
/// Every persistent component's own `reapplyTheme()` is unit-tested in `ReapplyThemeTests` /
/// `OverlayReapplyThemeTests`, but nothing failed if a line went missing from the observer's
/// hand-maintained list (`WindowController.swift` — `tabBar`, `dock`, `modal?.overlay`,
/// `confirmToast`, …) — the exact stale-chrome bug class ZEN-89 fixed. This mounts the real
/// chrome and drives the actual notification, so dropping `tabBar.reapplyTheme()` from the
/// fan-out fails a test rather than shipping stale chrome after a theme swap.
@MainActor
final class WindowControllerConfigFanOutTests: XCTestCase {
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
        // The real ghostty backend needs a live libghostty app, which a test bundle has no
        // business spinning up — inject a headless stub surface instead.
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDownWithError() throws {
        // The controller's own teardown (kills surfaces, invalidates the title poll, removes the
        // config observer) runs through its NSWindowDelegate entry point.
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        secondController?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        secondController = nil
        MotionConfig.apply(.system)
        TerminalSurfaceFactory.makeOverride = originalOverride
        Theme.setCurrentForTesting(originalTheme)
        GeneralConfig.setCurrentForTesting(originalConfig)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    /// A theme whose accent (ANSI slot 5) is a clearly distinct `#00ff00`, built via the same
    /// `ConfigLoader.loadAppTheme` path the other reapply tests use so every derived chrome role
    /// is populated exactly like a real theme swap.
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
        // The tracer underline is baked to `chrome.accent` at init and reset only by
        // `TabBarView.reapplyTheme()` — a faithful proxy for the fan-out reaching the tab bar.
        let accentBefore = tabBar.tracerColorForTesting
        XCTAssertNotNil(accentBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        NotificationCenter.default.post(name: .configDidChange, object: nil)

        // The observer is registered on `.main`, so its block runs as a queued main-queue op;
        // enqueue a fulfill after it (FIFO on the main run loop) and wait so it has run.
        // The observer is registered on `OperationQueue.main`, so drain on the SAME queue — a
        // `DispatchQueue.main` hop isn't guaranteed to sequence after an OperationQueue.main op.
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        // If the fan-out had dropped `tabBar.reapplyTheme()`, the tracer would still hold the old
        // baked-in accent. Slot 5 provably moved (Rosé Pine Moon → #00ff00), so a working fan-out
        // must change it.
        XCTAssertNotEqual(accentBefore, tabBar.tracerColorForTesting)
    }

    func test_configDidChange_appliesWindowChromeThroughTheFanOut() throws {
        var config = GeneralConfig.builtIn
        config.windowChrome = true
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        // Built with chrome on, so the traffic lights start visible.
        XCTAssertEqual(controller.window.standardWindowButton(.closeButton)?.isHidden, false)

        config.windowChrome = false
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(name: .configDidChange, object: nil)

        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        // If the fan-out had dropped `window.setWindowChromeVisible(...)`, the button would still be
        // visible. Driving the real notification proves the observer applies the toggle, not just
        // that the setter works in isolation.
        XCTAssertEqual(controller.window.standardWindowButton(.closeButton)?.isHidden, true)
    }

    // MARK: change-kind gating (ZEN-48)

    private func post(_ change: ConfigChange) {
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: change])
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// The ticket's motivating case: a keybind rebind must not drag the chrome recolor along with
    /// it. The theme is moved underneath to make a skipped re-apply *observable* — a working gate
    /// leaves the tracer on its old accent, because a `.keymap`-only change means the theme didn't
    /// actually move.
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

    /// The other half: `.theme` must still reach the tab bar, or the gate has traded a wasted
    /// frame for stale chrome.
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

    /// The audit's non-obvious dependency: recoloring a pane rebuilds its panel header keycap
    /// against the live keymap, so `.keymap` has to reach `reapplyChromeColors()` even though
    /// nothing about it sounds like a color. Gate that on `.theme` alone and a rebind leaves the
    /// drawer header showing the old chord.
    func test_keymapChange_rebuildsThePanelHeaderKeycap() throws {
        var config = GeneralConfig.builtIn
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.showAndStart()
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

        // Rebind Focus Mode (the drawer header's action) to a chord nothing else holds.
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

    /// The retraction has to reach the real toast stack, not just the applier's bookkeeping. The
    /// notice is sticky, so nothing takes it down on its own: if `dismissConfigDiagnosticsToast`
    /// missed, a warning about problems the user has already fixed stays on screen for the session.
    func test_dismissConfigDiagnosticsToast_takesTheNoticeOffScreen() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.showAndStart()

        controller.showConfigDiagnosticsToast(
            ToastContent(variant: .warning, title: "1 problem in your config", message: "a line"),
            landingScope: .keybindLine)
        func mountedToasts() -> [ToastView] {
            descendants(of: controller.window.contentView!).compactMap { $0 as? ToastView }
        }
        XCTAssertEqual(mountedToasts().count, 1, "expected the problem notice mounted")

        // Removal rides `animateOut`'s completion, so pin reduce-motion and let it land rather
        // than measuring mid-spring.
        let motion = Motion.isReduceMotionEnabled
        defer { Motion.isReduceMotionEnabled = motion }
        Motion.isReduceMotionEnabled = { true }
        controller.dismissConfigDiagnosticsToast()
        let settled = expectation(description: "dismissal settled")
        OperationQueue.main.addOperation { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(mountedToasts().isEmpty, "the notice is still on screen after being retracted")

        // Idempotent: a second retract (or one after the user already dismissed it) must not trap.
        controller.dismissConfigDiagnosticsToast()
    }

    // MARK: delivering the config-problems notice across windows

    /// Two windows, so the notice can be outstanding in one while the next lands in the other.
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

    /// The notice is app-global but lives in whichever window was key when it was raised, so a
    /// later one landing in a *different* window has to sweep the first. Nothing covered this: the
    /// applier's doubles model delivery as a single atomic step, so cross-window replacement was
    /// invisible to them, and this logic used to sit inline in an `AppDelegate` closure.
    func test_deliveringToAnotherWindow_sweepsTheNoticeOutOfTheFirst() throws {
        let first = makeWindow()
        controller = first
        let second = makeWindow()
        secondController = second
        first.showAndStart()
        second.showAndStart()
        Motion.isReduceMotionEnabled = { true }

        let windows = [first, second]
        XCTAssertTrue(
            WindowController.deliverConfigDiagnosticsNotice(
                ToastContent(variant: .warning, title: "1 problem in your config", message: "a"),
                landingScope: .keybindLine, to: first, replacingAcross: windows))
        settle()
        XCTAssertTrue(noticeTitles(in: first).contains("1 problem in your config"))

        // The key window is now the second one, and the replacement goes there.
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

    /// The ordering that a reversed sweep would break, and that no test reached until this became a
    /// static: with no window to take the replacement, nothing may be swept. Sweeping first would
    /// leave a broken config with an empty screen.
    func test_deliveringWithNoKeyWindow_leavesTheExistingNoticeUp() throws {
        let first = makeWindow()
        controller = first
        first.showAndStart()
        Motion.isReduceMotionEnabled = { true }

        XCTAssertTrue(
            WindowController.deliverConfigDiagnosticsNotice(
                ToastContent(variant: .warning, title: "1 problem in your config", message: "a"),
                landingScope: .keybindLine, to: first, replacingAcross: [first]))
        settle()

        // An open panel is key, so nothing of ours can host the replacement.
        XCTAssertFalse(
            WindowController.deliverConfigDiagnosticsNotice(
                ToastContent(variant: .warning, title: "2 problems in your config", message: "b"),
                landingScope: .keybindLine, to: nil, replacingAcross: [first]))
        settle()

        XCTAssertTrue(
            noticeTitles(in: first).contains("1 problem in your config"),
            "an undeliverable replacement swept the notice: the config is broken and nothing says so")
    }

    /// Every tool float is also a palette command, so adding one has to reach an open ⌘P: the
    /// `.floats` block rebuilt the dock's buttons and stopped there. Found by widening the
    /// differential fingerprint to sample every mounted view rather than a few named probes.
    ///
    /// The reachable path is **two windows**, which is what posting `.floats` at a window with its
    /// palette up models here. In one window `modal` is a single slot, so opening Settings has
    /// already closed the palette; and ⌘⌥R forces `.all`, which carries `.theme` and re-rendered
    /// the palette anyway. It takes window A holding a palette while window B saves a float, where
    /// the reload is unforced and broadcasts `.floats` on its own.
    func test_floatAdded_reachesAnOpenPaletteInAnotherWindow() throws {
        var config = GeneralConfig.builtIn
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.showAndStart()
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

    /// The same trap one layer out, and it was live until ZEN-281: an open command palette rebuilt
    /// its row *views* on `reapplyTheme()` but replayed the shortcut glyph each `PaletteCommand`
    /// baked in when the catalog built it, so a rebind left the palette showing the old chord. The
    /// gate was already right; the work behind it wasn't. A differential test can't see this on its
    /// own — both the gated and the ungated fan-out were equally stale.
    func test_keymapChange_reresolvesAnOpenPalettesShortcutColumn() throws {
        var config = GeneralConfig.builtIn
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.showAndStart()
        controller.handle(.toggleCommandPalette)

        /// The palette's own rows, excluding the drawer headers that resolve through a different path.
        func paletteKeycaps() throws -> [String] {
            let palette = descendants(of: controller.window.contentView!)
                .compactMap { $0 as? CommandPaletteOverlay }.first
            return try XCTUnwrap(palette, "expected the palette mounted").builtRowShortcutsForTesting
        }
        XCTAssertTrue(try paletteKeycaps().contains("⌘F"), "expected Focus Mode's default chord on a row")

        let rebound = Chord(command: true, shift: true, option: true, control: true, key: "j")
        config.keymap = config.keymap.filter { $0.value != .toggleZoom }
        config.keymap[rebound] = .toggleZoom
        GeneralConfig.setCurrentForTesting(config)
        post(.keymap)

        let after = try paletteKeycaps()
        XCTAssertFalse(after.contains("⌘F"), "the palette is still offering the chord that moved")
        XCTAssertTrue(
            after.contains(rebound.displayGlyph),
            "the rebind never reached the open palette's shortcut column")
    }
}
