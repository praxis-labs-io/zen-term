import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Scroll mode is sticky: once ⌘⇧S is pressed it holds an app-global key handler until something
/// takes it down. Every one of those retractions is the test.
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
    private var hosts: [ModeHostSpy] = []
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
        hosts = []
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
        // there is to read. Row 11 is the fixture's prompt and its last written row.
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11)
    }

    func test_theEntryRowIsReadFromTheScreenNotTheShellCursor() throws {
        // The shell's cursor is reported against the LIVE screen with no account of scrolling, so
        // a viewport the reader already scrolled with the trackpad put the band on an unrelated
        // row. The last written row of the viewport is right in every case.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        var rows = Array(repeating: "", count: 24)
        rows[3] = "scrolled-back output"  // history, nowhere near the live prompt
        surface.rows = rows
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 3)
    }

    func test_theModeFallsBackToTheBottomRowOnAnEmptyScreen() throws {
        // Nothing written anywhere still has to open somewhere sensible, and an empty pane's
        // prompt is at the bottom.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = Array(repeating: "", count: 24)
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

    func test_theBraceMotionLandsOnTheBlankRowAfterTheBlockAbove() throws {
        // The fixture screen: a command block, a blank, another block, a blank, the prompt on 11.
        // From the prompt, `{` crosses "~/bin" and stops on the blank at 9.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11)

        XCTAssertTrue(handler(try keyDown("{", unshifted: "[", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursorRow, 9)
        XCTAssertEqual(surface.scrolls, [], "a motion within the viewport moves the cursor, not the buffer")
    }

    func test_repeatedBraceMotionsWalkBlockByBlock() throws {
        // Each press crosses one block of text and stops on the blank before it, which is what
        // makes it useful for stepping back through command output.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("{", unshifted: "[", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 9)
        XCTAssertTrue(handler(try keyDown("{", unshifted: "[", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 6, "past the echo block to the blank above it")
        XCTAssertTrue(handler(try keyDown("{", unshifted: "[", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 1, "past the seq block; row 1 is blank")
    }

    func test_theBraceMotionClampsToTheTopRatherThanRunningOff() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<10 { XCTAssertTrue(handler(try keyDown("{", unshifted: "[", flags: .shift))) }

        XCTAssertEqual(controller.scrollMode.cursorRow, 0)
    }

    func test_theClosingBraceRunsToTheEndWhenOnlyBlanksFollow() throws {
        // Vim's behavior: } with no further paragraph goes to the end.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("}", unshifted: "]", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursorRow, 23)
    }

    func test_theMotionReadsTheScreenNotAScrollAction() throws {
        // The whole reason this is the chrome's own motion: jump_to_prompt scrolls the viewport to
        // a prompt ABOVE the screen, so it can never reach a prompt you are looking at.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("{", unshifted: "[", flags: .shift)))
        XCTAssertTrue(handler(try keyDown("}", unshifted: "]", flags: .shift)))

        XCTAssertEqual(surface.scrolls, [], "neither direction should ask the backend to scroll")
    }

    func test_aScreenTheBackendCannotReadStopsTheMotion() throws {
        // An unreadable row counts as blank, so the motion terminates instead of running the
        // cursor to the edge of a grid it knows nothing about.
        XCTAssertTrue(ScrollModeController.isBlank(nil))
        XCTAssertTrue(ScrollModeController.isBlank("   \t "))
        XCTAssertFalse(ScrollModeController.isBlank(" x "))
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

    func test_theModeDeclinesMenuKeyEquivalents() throws {
        // KeyInterceptor is a local monitor, so it runs before NSApp resolves menu equivalents.
        // ⌘C, ⌘V and ⌘Q are menu items rather than reserved chords, so nothing above the mode
        // claims them and swallowing them kills Copy and Quit for as long as the mode is up.
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
        // The other half: a bare or Control key would land in the buffer behind the mode.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("x")))
        XCTAssertTrue(handler(try keyDown("a", flags: .control)))
    }

    func test_aCloseConfirmEndsTheMode() throws {
        // A confirm answers with Return and Esc, both dispatched after the local monitor. Left
        // up, the mode eats the Return and reads the Esc as its own exit.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        XCTAssertTrue(controller.scrollMode.isActive)

        controller.presentConfirm(
            variant: .destructive, title: "Close Pane", message: "Running work will stop.",
            confirmLabel: "Close", onConfirm: {})

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertFalse(host.isInstalled)
    }

    func test_closingTheWindowEndsTheMode() throws {
        // A window closed while still key never resigns key, so the app-global handler would
        // outlive it and swallow keys in every other window.
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
        XCTAssertEqual(
            panel.headerContentForTesting?.title,
            "SCROLL: \(ScrollModeController.groupedCount(3760)) BELOW")

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

    // MARK: selection and yank

    /// A key handler and a pasteboard of its own, so a yank in the suite never clobbers the
    /// developer's clipboard.
    private func enterModeForYanking(_ controller: WindowController) throws -> (
        handler: (NSEvent) -> Bool, board: NSPasteboard
    ) {
        let host = ModeHostSpy()
        hosts.append(host)  // `keyModeHost` is weak, so the spy needs an owner outlasting this call
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let board = NSPasteboard(name: NSPasteboard.Name("zenterm-yank-\(UUID().uuidString)"))
        controller.scrollMode.yankPasteboard = board
        return (try XCTUnwrap(host.modeHandler), board)
    }

    func test_aCharacterSelectionYanksExactlyWhatItCovers() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        // Row 11 is the prompt the mode opens on; nine k's put the cursor on the `seq` command.
        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("v"))
        _ = handler(try keyDown("$", unshifted: "4", flags: .shift))
        _ = handler(try keyDown("y"))

        XCTAssertEqual(board.string(forType: .string), "❯ seq 1 3")
    }

    func test_aLineSelectionYanksWholeRowsWhicheverWayItWasDragged() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        // `V` on row 11, then up to row 10: the anchor is the LOWER end, which is the ordering an
        // unsorted span reads backwards and reads back as nothing.
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        _ = handler(try keyDown("k"))
        _ = handler(try keyDown("y"))

        XCTAssertEqual(board.string(forType: .string), "~/bin\n❯")
    }

    func test_aYankWithNothingSelectedLeavesThePasteboardAlone() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)
        board.clearContents()
        board.setString("what Drew had copied", forType: .string)

        _ = handler(try keyDown("y"))

        XCTAssertEqual(
            board.string(forType: .string), "what Drew had copied",
            "a bare y is a no-op, not an empty clipboard")
    }

    func test_theYankPulsesOnceTheCopyHasLanded() throws {
        let controller = makeWindow()
        let (handler, _) = try enterModeForYanking(controller)

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        XCTAssertFalse(controller.scrollMode.isFlashingForTesting, "nothing to confirm yet")
        _ = handler(try keyDown("y"))

        XCTAssertTrue(
            controller.scrollMode.isFlashingForTesting,
            "a yank leaves nothing on screen, so the pulse is the whole confirmation")
    }

    func test_theYankDropsBackToNormalModeRatherThanLeaving() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        _ = handler(try keyDown("y"))
        XCTAssertTrue(controller.scrollMode.isActive, "the mode stays up for a second yank")

        board.clearContents()
        _ = handler(try keyDown("y"))
        XCTAssertNil(board.string(forType: .string), "the selection was collapsed by the first yank")
    }

    func test_aScrollThatLandsGivesTheAnchorBack() throws {
        // `Point.pin` clamps an exact coordinate to the grid height for every tag, so a selection
        // that survived a page move would cover rows it no longer names.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let (handler, board) = try enterModeForYanking(controller)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        _ = handler(try keyDown("d", flags: .control))
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 112))
        _ = handler(try keyDown("y"))

        XCTAssertNil(board.string(forType: .string))
    }

    func test_outputThatScrollsThePaneGivesTheAnchorBack() throws {
        // No key is involved: a running build moves the viewport on its own, and a selection left
        // anchored to rows that slid up highlights output the reader never chose and yanks it.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let (handler, board) = try enterModeForYanking(controller)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 101))
        _ = handler(try keyDown("y"))

        XCTAssertNil(board.string(forType: .string))
    }

    func test_aScrollKeyThatMovesNothingKeepsTheSelection() throws {
        // `j` at the end of the buffer asks for a scroll that cannot happen. Releasing on the
        // keystroke took the selection away with nothing on screen having moved.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let (handler, board) = try enterModeForYanking(controller)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        for _ in 0..<14 { _ = handler(try keyDown("j")) }  // to the bottom row, then past it
        _ = handler(try keyDown("y"))

        XCTAssertNotNil(
            board.string(forType: .string),
            "nothing scrolled, so nothing reported, so the selection is still the reader's")
    }

    func test_aScrollDoesNotLeaveThePreviousScreenInTheRowCache() throws {
        // The row read that clamps the cursor happens between asking for the scroll and the frame
        // that serves it, so it describes the old viewport. Cached under the new one, the next
        // motion walks text that is no longer on screen.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<13 { _ = handler(try keyDown("j")) }  // to the bottom row, then one past it
        XCTAssertEqual(surface.scrolls, [.lines(1)], "precondition: the last j asked for a scroll")

        surface.rows[23] = "❯ what the scroll brought up"
        _ = handler(try keyDown("$", unshifted: "4", flags: .shift))

        XCTAssertEqual(
            controller.scrollMode.cursor.column, 27, "the row was re-read, not served from before the scroll")
    }

    func test_aFontStepGivesTheAnchorBack() throws {
        // The cursor can be found again by the line it was reading. The anchor is a bare row index
        // with no content behind it, so a reflow leaves it naming something else.
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        controller.applySessionFontSize()
        _ = handler(try keyDown("y"))

        XCTAssertNil(board.string(forType: .string))
    }

    func test_aKeyBeforeTheReflowReportCallsOffTheReanchor() throws {
        // libghostty emits a scrollbar only from a draw and only when it differs, so a font step in
        // a short buffer produces no report at all. Left armed, the re-anchor fires on whatever
        // report comes next and drags the cursor off the row the reader has since chosen.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the seq command")
        controller.applySessionFontSize()

        _ = handler(try keyDown("k"))  // the reader moves on, before any report arrives
        var reflowed = Array(repeating: "", count: 24)
        for (offset, text) in surface.rows.enumerated() where offset + 3 < 24 {
            reflowed[offset + 3] = text
        }
        surface.rows = reflowed
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 1, "the row the reader chose, not the line they left")
    }

    func test_aGridThatLosesRowsKeepsTheCursorsColumn() throws {
        // The row is clamped and the column bounded against it. Bounded against the pre-clamp row
        // instead, the backend refuses the read, the empty text reads as a zero-length row, and the
        // cursor snaps to the left margin with the selection's moving end behind it.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "❯ tail -f /var/log/system.log"
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        _ = handler(try keyDown("$", unshifted: "4", flags: .shift))
        XCTAssertEqual(controller.scrollMode.cursor.column, 28, "precondition: at the end of the line")

        surface.cellMetrics = TerminalCellMetrics(
            columns: 80, rows: 8, cellWidth: 8, cellHeight: 16, gridInset: 2)
        controller.applySessionFontSize()  // any refresh re-clamps against the new grid

        XCTAssertEqual(controller.scrollMode.cursorRow, 7)
        XCTAssertEqual(
            controller.scrollMode.cursor.column, 8, "the last column of row 7, not the left margin")
    }

    func test_theEndOfLineStopsAtTheLastCharacterThePaneShows() throws {
        // `read_text` reads with `trim = false`, so a row a program painted edge to edge comes back
        // padded to the grid width. `$` on the padding parks the cursor out past the text and a
        // `v$y` copies a run of spaces.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "❯ ls" + String(repeating: " ", count: 76)
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("v"))
        _ = handler(try keyDown("$", unshifted: "4", flags: .shift))

        XCTAssertEqual(controller.scrollMode.cursor.column, 3, "the s of ls, not column 79")
        _ = handler(try keyDown("y"))
        XCTAssertEqual(board.string(forType: .string), "❯ ls")
    }

    func test_aYankOfABlankRowStillConfirms() throws {
        // The pulse is the only evidence a yank happened. Dropping out on an empty read left the
        // screen identical to before the keystroke, which is exactly what a failed copy looks like.
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("G", unshifted: "g", flags: .shift))  // the blank bottom row
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        _ = handler(try keyDown("y"))

        XCTAssertEqual(board.string(forType: .string), "")
        XCTAssertTrue(controller.scrollMode.isFlashingForTesting)
        XCTAssertNil(controller.scrollMode.selection, "the gesture completed, so the selection is spent")
    }

    func test_escapeGivesTheSelectionBackBeforeItClosesTheMode() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        _ = handler(try keyDown("\u{1b}", keyCode: 53))
        XCTAssertTrue(controller.scrollMode.isActive, "the first Esc gives back the selection only")
        _ = handler(try keyDown("y"))
        XCTAssertNil(board.string(forType: .string), "and the selection really is gone")

        _ = handler(try keyDown("\u{1b}", keyCode: 53))
        XCTAssertFalse(controller.scrollMode.isActive, "the second one closes the mode")
    }

    func test_theSameVisualKeyTwiceClosesTheSelection() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("v"))
        _ = handler(try keyDown("v"))
        _ = handler(try keyDown("y"))

        XCTAssertNil(board.string(forType: .string))
        XCTAssertTrue(controller.scrollMode.isActive)
    }

    func test_theHeaderNamesTheSelectionAndItsSize() throws {
        let controller = makeWindow()
        let (handler, _) = try enterModeForYanking(controller)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        XCTAssertEqual(panel.headerContentForTesting?.title, "VISUAL: 1 LINE")
        _ = handler(try keyDown("k"))
        XCTAssertEqual(panel.headerContentForTesting?.title, "VISUAL: 2 LINES")
        _ = handler(try keyDown("\u{1b}", keyCode: 53))
        XCTAssertEqual(panel.headerContentForTesting?.title, "SCROLL")
    }

    func test_endingTheModeDropsTheSelectionWithIt() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        controller.handle(.toggleScrollMode)  // out
        controller.handle(.toggleScrollMode)  // and back in
        let reopened = try XCTUnwrap((controller.keyModeHost as? ModeHostSpy)?.modeHandler)
        controller.scrollMode.yankPasteboard = board
        _ = reopened(try keyDown("y"))

        XCTAssertNil(board.string(forType: .string), "a reopened mode starts in normal mode")
    }

    func test_aFontStepRedrawsTheBandThoughNothingAboutItMoved() throws {
        // No layout pass runs and the overlay's state is identical either way, so a redraw keyed
        // off that state leaves the band at the old row height.
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let overlay = panel.scrollCursorForTesting
        let before = overlay.redrawRequestsForTesting

        controller.applySessionFontSize()

        XCTAssertGreaterThan(
            overlay.redrawRequestsForTesting, before,
            "the band has to be redrawn against the new cell size")
    }

    func test_aFontStepKeepsTheBandOnTheLineItWasReading() throws {
        // A font step resizes the grid in both directions and the text rewraps into it, so the row
        // INDEX the band held names a different line afterward.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the seq command")

        controller.applySessionFontSize()
        // The reflow: a smaller font fits three more rows, so everything on screen slid down.
        var reflowed = Array(repeating: "", count: 24)
        for (offset, text) in surface.rows.enumerated() where offset + 3 < 24 {
            reflowed[offset + 3] = text
        }
        surface.rows = reflowed
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 200, offset: 176, viewport: 24))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 5, "the band follows the line, not the row number")
    }

    func test_aReflowThatLosesTheLineLeavesTheBandWhereItIs() throws {
        // Nothing to re-find is not a reason to jump.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        for _ in 0..<9 { _ = handler(try keyDown("k")) }

        controller.applySessionFontSize()
        surface.rows = Array(repeating: "", count: 24)
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 200, offset: 176, viewport: 24))

        XCTAssertEqual(controller.scrollMode.cursorRow, 2)
    }

    func test_theModeRendersTheTerminalUnfocusedAndGivesItBackOnExit() throws {
        // The shell takes no keys while the mode is up, so its blinking cursor competes with the
        // mode's own. Left focused it blinks through the whole session; left unfocused after the
        // mode ends, the pane you are typing into has a dead cursor and nothing says why.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(surface.focusRenders.last, false)

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(surface.focusRenders.last, true)
    }

    // MARK: helpers

    /// A report against a 200-line buffer. Only `offset` matters to these tests: it is what says
    /// the rows on screen moved.
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
