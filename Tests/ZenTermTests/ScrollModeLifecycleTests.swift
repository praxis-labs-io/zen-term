import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Scroll mode is sticky: once ⌘⇧S is pressed it holds an app-global key handler until something
/// takes it down. Every one of those retractions is the test (ZEN-330).
///
/// The failure is not cosmetic. A mode left up over a pane you walked away from keeps swallowing
/// every keystroke that isn't a reserved chord, so the terminal you switched to goes deaf, and the
/// only visible clue is a header on a panel you're no longer looking at.
@MainActor
final class ScrollModeLifecycleTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    /// A float to open in the "a float takes the keyboard" case. There are no built-in floats,
    /// so a test that opens one has to configure it.
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
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.showAndStart()
        controllers.append(controller)
        return controller
    }

    /// A fake interceptor, so a test can see whether the app-global key handler is installed
    /// rather than only whether a flag flipped.
    private final class ModeHostSpy: KeyModeHosting {
        var modeHandler: ((NSEvent) -> Bool)?
        var isInstalled: Bool { modeHandler != nil }
    }

    // MARK: entering

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

    func test_theFocusedPaneWearsTheHeaderAndGivesItBackOnExit() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        XCTAssertFalse(panel.isHeaderVisibleForTesting, "a resting pane shows no header")

        controller.handle(.toggleScrollMode)
        XCTAssertTrue(panel.isHeaderVisibleForTesting)
        XCTAssertEqual(panel.headerContentForTesting?.title, "SCROLL")

        controller.handle(.toggleScrollMode)
        XCTAssertFalse(panel.isHeaderVisibleForTesting, "the header must come down with the mode")
    }

    // MARK: the keys, through the real handler

    func test_aKeyThroughTheInstalledHandlerScrollsTheFocusedSurface() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)

        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("d", flags: .control)))
        XCTAssertTrue(handler(try keyDown("u", flags: .control)))
        XCTAssertTrue(handler(try keyDown("G", unshifted: "g", flags: .shift)))

        XCTAssertEqual(surface.scrolls, [.pageFraction(0.5), .pageFraction(-0.5), .bottom])
    }

    // MARK: the cursor

    func test_theModeOpensOnTheLastWrittenLineNotTheBottomOfThePane() throws {
        // On a half-filled screen the bottom of the viewport is empty space below everything
        // there is to read. The terminal's own cursor is the last written line.
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "the surface reports its cursor on row 11")
    }

    func test_theModeFallsBackToTheBottomRowWhenTheCursorIsUnknown() throws {
        // A backend that can't locate its cursor still has to open somewhere sensible.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.cursorRow = nil
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 23)
    }

    func test_kMovesTheCursorWithoutScrolling() throws {
        // The distinction that makes it a cursor rather than a scrollbar: for the height of the
        // viewport, `k` moves a marker and the text underneath stays put.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<5 { XCTAssertTrue(handler(try keyDown("k"))) }

        XCTAssertEqual(controller.scrollMode.cursorRow, 6)
        XCTAssertEqual(surface.scrolls, [], "nothing should have scrolled while the cursor had room")
    }

    func test_theViewportOnlyMovesOnceTheCursorIsPinned() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<11 { XCTAssertTrue(handler(try keyDown("k"))) }  // cursor to the top row
        XCTAssertEqual(controller.scrollMode.cursorRow, 0)
        XCTAssertEqual(surface.scrolls, [])

        XCTAssertTrue(handler(try keyDown("k")))  // nowhere left to go

        XCTAssertEqual(controller.scrollMode.cursorRow, 0, "the cursor stays pinned at the edge")
        XCTAssertEqual(surface.scrolls, [.lines(-1)], "and the buffer moves under it instead")
    }

    func test_ggAndGCarryTheCursorToTheEndsTheyName() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("g")))
        XCTAssertTrue(handler(try keyDown("g")))
        XCTAssertEqual(controller.scrollMode.cursorRow, 0)

        XCTAssertTrue(handler(try keyDown("G", unshifted: "g", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 23)
    }

    func test_aPromptJumpThatMovesTheViewportPutsTheCursorOnThePrompt() throws {
        // libghostty scrolls to a prompt by pinning the viewport's top row to it, so a jump that
        // scrolls leaves the prompt on row 0.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("[")))
        XCTAssertEqual(surface.scrolls, [.prompt(-1)])
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "nothing has landed yet")

        // The viewport reports it moved, with scrollback still below it.
        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 5000, offset: 1200, viewport: 24))

        XCTAssertEqual(controller.scrollMode.cursorRow, 0)
    }

    func test_aPromptJumpThatScrollsNothingLeavesTheCursorAlone() throws {
        // The reported bug. `scrollPrompt` returns without moving when there is no prompt that
        // way, and moving the cursor anyway sent the band to the top of a screen that never
        // scrolled, which reads as "it jumped to the top instead of to a prompt".
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("[")))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 11,
            "no scroll report means the viewport never moved, so the cursor must not either")
    }

    func test_aPromptJumpLandingAtTheBottomLeavesTheCursorAlone() throws {
        // A prompt already on the live screen takes libghostty's `pinIsActive` branch, which goes
        // to the bottom rather than pinning. The prompt is then somewhere on the active screen and
        // the chrome cannot see which row, so row 0 would be a guess.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("]")))
        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 500, offset: 476, viewport: 24))

        XCTAssertEqual(controller.scrollMode.cursorRow, 11)
    }

    func test_aLaterScrollReportDoesNotRetroactivelyMoveTheCursor() throws {
        // Output arriving after a jump has landed must not be read as a second landing.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("[")))
        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 5000, offset: 1200, viewport: 24))
        XCTAssertEqual(controller.scrollMode.cursorRow, 0)

        for _ in 0..<4 { XCTAssertTrue(handler(try keyDown("j"))) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 4)

        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 5001, offset: 1200, viewport: 24))

        XCTAssertEqual(controller.scrollMode.cursorRow, 4)
    }

    func test_aPageMoveLeavesTheCursorWhereItIsOnScreen() throws {
        // A page move carries the cursor with the viewport, so your place on screen is kept.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<5 { XCTAssertTrue(handler(try keyDown("k"))) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 6)

        XCTAssertTrue(handler(try keyDown("u", flags: .control)))

        XCTAssertEqual(controller.scrollMode.cursorRow, 6)
    }

    func test_theCursorIsClampedToAShrunkenGrid() throws {
        // A pane resized smaller while the mode is up must not leave the band off the grid.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11)

        surface.cellMetrics = TerminalCellMetrics(
            columns: 80, rows: 8, cellWidth: 8, cellHeight: 16, gridInset: 2)
        XCTAssertTrue(handler(try keyDown("k")))

        XCTAssertLessThanOrEqual(controller.scrollMode.cursorRow, 7)
    }

    func test_ggTopsOutOnlyOnTheSecondG() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)

        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("g")))
        XCTAssertEqual(surface.scrolls, [], "one g arms the prefix and scrolls nothing")
        XCTAssertTrue(handler(try keyDown("g")))
        XCTAssertEqual(surface.scrolls, [.top])
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

    // MARK: the retractions

    func test_movingPaneFocusEndsTheMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.splitVertical)
        // Pane nav scores real geometry, so an unlaid-out canvas has every frame at zero and
        // finds no neighbor to move to.
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.handle(.navLeft)
        XCTAssertNotIdentical(
            controller.focusedPanelForTesting, panel, "the nav must actually have moved focus")

        XCTAssertFalse(controller.scrollMode.isActive, "the mode targets one panel; focus moved off it")
        XCTAssertFalse(host.isInstalled)
        XCTAssertFalse(panel.isHeaderVisibleForTesting)
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
        // A float takes the keyboard without moving pane focus, so nothing in the focus path
        // fires. Left up, the mode would swallow every key typed at the float.
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

    // MARK: the indicator's live text

    func test_theHeaderTracksTheReportedScrollPosition() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let surface = try XCTUnwrap(spawned.first)

        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 5000, offset: 1200, viewport: 40))
        XCTAssertEqual(panel.headerContentForTesting?.title, "SCROLL: 3,760 BELOW")

        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 5000, offset: 4960, viewport: 40))
        XCTAssertEqual(panel.headerContentForTesting?.title, "SCROLL: AT BOTTOM")
    }

    func test_aReportFromAnotherPaneDoesNotMoveTheHeader() throws {
        let controller = makeWindow()
        controller.handle(.splitHorizontal)
        controller.handle(.toggleScrollMode)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let driven = try XCTUnwrap(controller.focusedSurfaceForTesting as? RecordingSurface)
        let other = try XCTUnwrap(spawned.first { $0 !== driven })

        other.delegate?.surface(
            other, scrollPositionDidChange: TerminalScrollPosition(total: 5000, offset: 1200, viewport: 40))

        XCTAssertEqual(
            panel.headerContentForTesting?.title, "SCROLL",
            "a busy sibling pane must not rewrite the header of the pane being read")
    }

    // MARK: helpers

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
