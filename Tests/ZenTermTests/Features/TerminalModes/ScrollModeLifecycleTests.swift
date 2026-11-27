import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ScrollModeLifecycleTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var hosts: [ModeHostSpy] = []
    private var root = FileManager.default.temporaryDirectory

    private static func spec(_ id: String) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon, command: id, dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: .window,
            toggle: Chord(command: true, shift: true, key: "b"))
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        var config = GeneralConfig.builtIn
        config.floats = [Self.spec("btop")]
        GeneralConfig.setCurrentForTesting(config)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-scroll-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        spawned = []
        hosts = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.mountAndStart()
        controllers.append(controller)
        return controller
    }

    private final class ModeHostSpy: KeyModeHosting {
        var modeHandler: ((NSEvent) -> Bool)?
        var isInstalled: Bool { modeHandler != nil }
    }

    func test_theChordEntersTheModeAndInstallsTheKeyHandler() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host

        controller.handle(.toggleScrollMode)

        XCTAssertTrue(controller.scrollMode.isActive)
        XCTAssertTrue(host.isInstalled, "without the handler installed no bare key ever reaches the mode")
    }

    func test_theChordAgainLeavesIt() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host

        controller.handle(.toggleScrollMode)
        controller.handle(.toggleScrollMode)

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled)
    }

    func test_enteringScrollMode_resizesNothing() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "❯ echo hello"
        var resizes = 0
        surface.resizingView.onResize = { resizes += 1 }

        controller.handle(.toggleScrollMode)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(resizes, 0, "the mode reports in the header's detail, so the grid keeps its height")
    }

    func test_anUnmappedKeyIsSwallowedRatherThanLeakedToTheShell() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)

        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("x")), "a stray x must not reach the shell behind the mode")
        XCTAssertEqual(surface.scrolls, [])
    }

    func test_theModeDeclinesMenuKeyEquivalents() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertFalse(handler(try keyDown("c", flags: .command)), "⌘C must reach the menu")
        XCTAssertFalse(handler(try keyDown("q", flags: .command)), "⌘Q must reach the menu")
        XCTAssertFalse(handler(try keyDown("f", flags: [.command, .option])), "⌘⌥F is not ours")
        XCTAssertTrue(controller.scrollMode.isActive, "declining a key must not end the mode")
    }

    func test_theModeStillSwallowsKeysThatWouldReachTheShell() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("x")))
        XCTAssertTrue(handler(try keyDown("a", flags: .control)))
    }

    func test_aCloseConfirmEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.presentConfirm(
            ConfirmPrompt(title: "Close Pane", body: .message("Running work will stop."), confirmLabel: "Close"),
            onConfirm: {})

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled)
    }

    func test_closingTheWindowEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled)
    }

    func test_escapeLeavesTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)

        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertTrue(handler(try keyDown("\u{1b}", keyCode: 53)))

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled)
    }

    func test_movingPaneFocusEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.splitVertical)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.handle(.navLeft)
        XCTAssertNotIdentical(
            controller.focusedPanelForTesting, panel, "the nav must actually have moved focus")

        XCTAssertFalse(controller.scrollMode.isActive, "the mode targets one panel; focus moved off it")
        XCTAssertFalse(host.isInstalled)
    }

    func test_focusModeKeepsTheModeUpOverTheSamePane() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.splitVertical)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.handle(.toggleZoom)

        XCTAssertTrue(controller.scrollMode.isActive, "zooming is not leaving the pane")
        XCTAssertTrue(host.isInstalled)
        XCTAssertIdentical(controller.focusedPanelForTesting, panel)
    }

    func test_leavingFocusModeKeepsTheModeUpToo() throws {
        let controller = makeWindow()
        controller.handle(.splitVertical)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.handle(.toggleScrollMode)

        controller.handle(.toggleZoom)
        controller.handle(.toggleZoom)

        XCTAssertTrue(controller.scrollMode.isActive, "unzoom re-focuses the same leaf as the zoom did")
    }

    func test_focusModeLeavesTheShellsCursorDark() throws {
        let controller = makeWindow()
        controller.handle(.splitVertical)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(
            controller.focusedScrollTargetForTesting?.surface as? RecordingSurface)
        XCTAssertEqual(surface.focusRenders.last, false)

        controller.handle(.toggleZoom)

        XCTAssertEqual(surface.focusRenders.last, false, "the shell is still not taking keys")
    }

    func test_closingThePaneEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.splitHorizontal)
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.handle(.closePane)

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled, "a handler outliving its pane goes on swallowing every key")
    }

    func test_switchingTabsEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.newTab)
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.handle(.prevTab)

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled)
    }

    func test_openingAToolFloatEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.handle(.toggleToolFloat("btop"))

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled)
    }

    func test_openingAModalCardEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.handle(.toggleCommandPalette)

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled, "the palette's search field owns the keyboard now")
    }

    func test_losingKeyWindowEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled, "the handler is app-global and would deafen the next window")
    }

    func test_aTabSwitchGivesTheOldTabItsLiveCursorBack() throws {
        let controller = makeWindow()
        let first = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(first.focusRenders.last, false)

        controller.handle(.newTab)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.selectTabForTesting(index: 0)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertEqual(
            first.focusRenders.last, true, "no mode is up, so the pane's own cursor is live again")
    }

    func test_outputAtTheLiveEndIsPulledBackOffTheBand() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        XCTAssertEqual(surface.scrolls, [.lines(-3)], "the three rows the output pushed")
    }

    func test_aReaderReachingTheLiveEndIsLeftThere() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))

        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(surface.scrolls, [], "the buffer never grew, so nothing pushed the screen")
    }

    func test_outputUnderAScrolledBackReaderMovesNothing() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))

        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 210, offset: 100, viewport: 24))

        XCTAssertEqual(surface.scrolls, [])
    }

    func test_leavingHandsBackTheLiveEndItHeld() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(surface.scrolls, [.lines(-3), .bottom])
    }

    func test_leavingAScrolledBackReaderKeepsTheirPlace() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 210, offset: 100, viewport: 24))

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(surface.scrolls, [], "nothing was held, so there is nothing to hand back")
    }

    func test_leavingKeepsAPlaceTheReaderChoseAfterAHold() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 176, viewport: 24))

        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 40, viewport: 24))
        controller.handle(.toggleScrollMode)

        XCTAssertEqual(surface.scrolls, [.lines(-3)], "no `.bottom`: they are where they chose to be")
    }

    func test_aRewrapAtTheLiveEndIsNotReadAsOutput() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        surface.cellMetrics = TerminalCellMetrics(columns: 60, rows: 24, cellWidth: 8, cellHeight: 16, gridInset: 2)
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        XCTAssertEqual(surface.scrolls, [], "the rewrap put those rows there; nothing pushed a screen")
    }

    func test_theModeRendersTheTerminalUnfocusedAndGivesItBackOnExit() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(surface.focusRenders.last, false)

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(surface.focusRenders.last, true)
    }

    private static func position(offset: Int) -> TerminalScrollPosition {
        TerminalScrollPosition(total: 200, offset: offset, viewport: 24)
    }

    private func keyDown(
        _ characters: String, unshifted: String? = nil, flags: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters,
                charactersIgnoringModifiers: unshifted ?? characters, isARepeat: false, keyCode: keyCode))
    }
}
