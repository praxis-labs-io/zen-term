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
        let surface = try XCTUnwrap(spawned.first)
        surface.grid = nil
        controller.handle(.toggleScrollMode)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        XCTAssertEqual(surface.scrolls, [.lines(-3)], "the three rows the output pushed")
    }

    func test_aPullThatLandsShortDuringABurstIsPulledTheRestOfTheWay() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = (0..<200).map { "line \($0)" }
        surface.recordingGrid.viewportTop = 176
        controller.handle(.toggleScrollMode)
        controller.scrollMode.land(on: TerminalGridPoint(row: 180, column: 0))
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))
        XCTAssertEqual(surface.scrolls, [.lines(-3)], "precondition: the first push is held")

        surface.rows = (0..<300).map { "line \($0)" }
        surface.recordingGrid.viewportTop = 230
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 300, offset: 230, viewport: 24))

        XCTAssertEqual(surface.scrolls, [.lines(-3), .lines(-54)], "back to the held offset, not the report's")
        XCTAssertEqual(controller.scrollMode.cursor?.row, 180, "the cursor stays on its text, off the burst")
    }

    func test_aMoveOffTheHeldScreenDuringABurstIsNotPulledBack() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = (0..<200).map { "line \($0)" }
        surface.recordingGrid.viewportTop = 176
        controller.handle(.toggleScrollMode)
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        controller.scrollMode.land(on: TerminalGridPoint(row: 100, column: 0))
        surface.rows = (0..<210).map { "line \($0)" }
        surface.recordingGrid.viewportTop = 100
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 210, offset: 100, viewport: 24))

        XCTAssertEqual(surface.scrolls, [.lines(-3), .lines(-76)], "the reveal stands; nothing pulls it back")
        XCTAssertEqual(controller.scrollMode.cursor?.row, 100)
    }

    func test_aReaderScrollingUpDuringABurstIsNotPulledBack() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = (0..<200).map { "line \($0)" }
        surface.recordingGrid.viewportTop = 176
        controller.handle(.toggleScrollMode)
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))
        XCTAssertEqual(surface.scrolls, [.lines(-3)], "precondition: the first push is held")

        surface.rows = (0..<210).map { "line \($0)" }
        surface.recordingGrid.viewportTop = 150
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 210, offset: 150, viewport: 24))

        XCTAssertEqual(surface.scrolls, [.lines(-3)], "the reader's scroll up stands")
        XCTAssertEqual(controller.scrollMode.lastPositionForTesting?.offset, 150)
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
        let surface = try XCTUnwrap(spawned.first)
        surface.grid = nil
        controller.handle(.toggleScrollMode)
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
        let surface = try XCTUnwrap(spawned.first)
        surface.grid = nil
        controller.handle(.toggleScrollMode)
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
        let surface = try XCTUnwrap(spawned.first)
        surface.grid = nil
        controller.handle(.toggleScrollMode)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        surface.cellMetrics = TerminalCellMetrics(columns: 60, rows: 24, cellWidth: 8, cellHeight: 16, gridInset: 2)
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        XCTAssertEqual(surface.scrolls, [], "the rewrap put those rows there; nothing pushed a screen")
    }

    func test_aParagraphWalkWithNoStopEndsAtTheCap() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        let limit = ScrollModeController.paragraphWalkLimit
        surface.rows = Array(repeating: "x", count: 2 * limit + 1)
        controller.handle(.toggleScrollMode)
        controller.scrollMode.land(on: TerminalGridPoint(row: 2 * limit, column: 0))

        XCTAssertTrue(try XCTUnwrap(host.modeHandler)(try keyDown("{", unshifted: "[", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursor?.row, limit, "the walk stops at the cap, not the top")
    }

    func test_outputAfterAFontStepIsStillHeld() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.grid = nil
        controller.handle(.toggleScrollMode)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))
        surface.cellMetrics = TerminalCellMetrics(columns: 60, rows: 24, cellWidth: 11, cellHeight: 22, gridInset: 2)

        controller.applySessionFontSize()
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        XCTAssertEqual(surface.scrolls, [.lines(-3)], "the step already took the new size, so this is output")
    }

    func test_theModeRendersTheTerminalUnfocusedAndGivesItBackOnExit() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(surface.focusRenders.last, false)

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(surface.focusRenders.last, true)
    }

    func test_theModeTurnsTheHeaderToItsChipAndName_andLeavingGivesThemBack() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        panel.shownHeaderForTesting?.content.path = "~/dev"
        let header = try XCTUnwrap(panel.shownHeaderForTesting)
        let name = header.nameForTesting
        XCTAssertNotEqual(name, "Scroll mode", "premise: the pane has its own name")

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(header.chipForTesting, .scrollMode)
        XCTAssertEqual(header.nameForTesting, "Scroll mode")
        XCTAssertNil(header.pathForTesting, "the path steps aside")
        XCTAssertTrue(header.showsTitleAndControlsForTesting, "the controls stay")

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(header.chipForTesting, header.processForTesting)
        XCTAssertEqual(header.nameForTesting, name)
        XCTAssertEqual(header.pathForTesting, "~/dev")
    }

    func test_findOverTheMode_keepsFindsChipAndField_untilItCloses() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let header = try XCTUnwrap(panel.shownHeaderForTesting)
        controller.handle(.toggleScrollMode)

        controller.handle(.toggleSearch)
        XCTAssertEqual(header.chipForTesting, .find)
        XCTAssertFalse(header.showsTitleAndControlsForTesting)

        controller.search.end()
        XCTAssertTrue(controller.scrollMode.isActive, "premise: the reader's own mode outlives find")
        XCTAssertEqual(header.chipForTesting, .scrollMode)
        XCTAssertEqual(header.nameForTesting, "Scroll mode")
    }

    func test_findHandingOffToTheMode_keepsFindsChip() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let header = try XCTUnwrap(panel.shownHeaderForTesting)
        controller.handle(.toggleSearch)

        controller.search.enterScrollMode()

        XCTAssertTrue(controller.scrollMode.isActive)
        XCTAssertEqual(header.chipForTesting, .find)
        XCTAssertFalse(header.showsTitleAndControlsForTesting)
    }

    func test_theHeadersPositionFollowsTheRowsTheScrollbackDrops() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = Array(repeating: "", count: 200)
        let grid = surface.recordingGrid
        grid.viewportTop = 176
        grid.cursorPoint = TerminalGridPoint(row: 190, column: 0)
        let header = try XCTUnwrap(controller.focusedPanelForTesting?.shownHeaderForTesting)
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(header.readoutForTesting, "191:1", "precondition")

        grid.droppedRows = 50
        grid.viewportTop = 126
        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 200, offset: 126, viewport: 24))

        XCTAssertEqual(controller.scrollMode.cursor?.row, 140, "premise: the cursor's text renumbered")
        XCTAssertEqual(header.readoutForTesting, "141:1")
    }

    func test_aScrollThatCarriesTheCursorOffscreenGivesThePositionBackAfterACopy() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = Array(repeating: "x", count: 200)
        let grid = surface.recordingGrid
        grid.viewportTop = 176
        grid.cursorPoint = TerminalGridPoint(row: 190, column: 0)
        let board = NSPasteboard(name: NSPasteboard.Name("zenterm-scroll-mode-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        controller.scrollMode.yankPasteboard = board
        let header = try XCTUnwrap(controller.focusedPanelForTesting?.shownHeaderForTesting)
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertTrue(handler(try keyDown("y")))
        XCTAssertTrue(handler(try keyDown("y")))
        XCTAssertEqual(header.readoutForTesting, "Copied 1 line", "precondition")

        grid.viewportTop = 100
        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 200, offset: 100, viewport: 24))

        XCTAssertEqual(controller.scrollMode.cursor?.row, 123, "premise: the scroll carried the cursor")
        XCTAssertEqual(header.readoutForTesting, "124:1")
    }

    func test_withHeadersOff_theModeLeavesTheHeaderHidden() throws {
        var config = GeneralConfig.current
        config.paneHeaders = false
        GeneralConfig.setCurrentForTesting(config)
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)

        controller.handle(.toggleScrollMode)

        XCTAssertTrue(controller.scrollMode.isActive)
        XCTAssertNil(panel.shownHeaderForTesting)
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
