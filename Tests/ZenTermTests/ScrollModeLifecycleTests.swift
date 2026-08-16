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

    // MARK: where it opens

    /// Puts the band where the reader was already looking, not a screenful away on the last row.
    func test_enteringOverASelection_landsOnItsFirstCell() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.selectionOrigin = TerminalViewportCell(row: 2, column: 4)  // row 2 is "❯ seq 1 3"

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(controller.scrollMode.cursorRow, 2)
        XCTAssertEqual(controller.scrollMode.cursor.column, 4)
    }

    func test_enteringWithNoSelection_stillOpensOnTheLastWrittenRow() throws {
        let controller = makeWindow()

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "the fixture's prompt row")
    }

    func test_theEntryRowIsReadBeforeTheHeaderBlanksThePrompt() throws {
        // The header costs the grid rows and SIGWINCHes the pty, and a shell redrawing a multi-line
        // prompt clears it first. Read after that, the walk-up skips it and stops on older output.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "❯ echo hello"
        surface.resizingView.onResize = { [weak surface] in
            guard let surface, !surface.rows[11].isEmpty else { return }
            surface.rows[10] = ""
            surface.rows[11] = ""
        }

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "the prompt, not the output above it")
    }

    func test_theEntryRowFollowsThePromptTheResizeMoved() throws {
        // The whole sequence the app runs: the header resizes the surface, the reflow reports from
        // inside that resize, and the shell repaints its prompt elsewhere a frame later.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "❯ echo hello"
        surface.resizingView.onResize = { [weak surface] in
            guard let surface, !surface.rows[11].isEmpty else { return }
            surface.rows[10] = ""
            surface.rows[11] = ""
            surface.delegate?.surfaceGridDidReflow(surface)
        }

        controller.handle(.toggleScrollMode)
        var repainted = Array(repeating: "", count: 24)
        repainted[9] = "❯ echo hello"  // two rows up, the grid having lost two
        surface.rows = repainted
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(controller.scrollMode.cursorRow, 9, "the band followed the prompt")
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

    // MARK: the motions counts came with

    func test_caretGoesToTheFirstCellHoldingSomething() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "    indented"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("$", unshifted: "4", flags: .shift)))
        XCTAssertTrue(handler(try keyDown("^", unshifted: "6", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursor.column, 4, "past the four spaces, not to 0")
    }

    func test_hmlLandOnTheTopMiddleAndLastWrittenRow() throws {
        // `L` reckons from the last row with anything on it. The grid's own bottom is empty space
        // below the prompt, and parking the band out there names nothing the reader can read.
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("H", unshifted: "h", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 0)

        XCTAssertTrue(handler(try keyDown("L", unshifted: "l", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "the prompt, not row 23")

        XCTAssertTrue(handler(try keyDown("M", unshifted: "m", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 5)
    }

    func test_aCountOffsetsHFromTheTopRow() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("3")))
        XCTAssertTrue(handler(try keyDown("H", unshifted: "h", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "the third row down")
    }

    func test_shiftWCrossesPunctuationThatWStopsOn() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "foo.bar baz"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("w")))
        XCTAssertEqual(controller.scrollMode.cursor.column, 3, "bare `w` stops on the dot")

        XCTAssertTrue(handler(try keyDown("0")))
        XCTAssertTrue(handler(try keyDown("W", unshifted: "w", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursor.column, 8, "a WORD crosses it to `baz`")
    }

    func test_starOpensTheFindBarOnTheWordUnderTheBand() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<3 { XCTAssertTrue(handler(try keyDown("k"))) }  // onto "hi"
        XCTAssertEqual(controller.scrollMode.cursorRow, 8, "precondition")
        XCTAssertTrue(handler(try keyDown("*", unshifted: "8", flags: .shift)))

        XCTAssertEqual(panel.findBarForTesting?.needle, "hi")
    }

    // MARK: the two-key commands, through the real handler

    func test_yyTakesWholeRowsWithoutAVisualFirst() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let board = NSPasteboard(name: NSPasteboard.Name("zenterm-yank-\(UUID().uuidString)"))
        controller.handle(.toggleScrollMode)
        controller.scrollMode.yankPasteboard = board
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<4 { XCTAssertTrue(handler(try keyDown("k"))) }  // onto "❯ echo hi"
        XCTAssertTrue(handler(try keyDown("y")))
        XCTAssertTrue(handler(try keyDown("y")))

        XCTAssertEqual(board.string(forType: .string), "❯ echo hi")
        XCTAssertNil(controller.scrollMode.selection, "no selection was opened to take it")
    }

    func test_aCountOnYYTakesThatManyRows() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let board = NSPasteboard(name: NSPasteboard.Name("zenterm-yank-\(UUID().uuidString)"))
        controller.handle(.toggleScrollMode)
        controller.scrollMode.yankPasteboard = board
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { XCTAssertTrue(handler(try keyDown("k"))) }  // onto "❯ seq 1 3"
        XCTAssertTrue(handler(try keyDown("2")))
        XCTAssertTrue(handler(try keyDown("y")))
        XCTAssertTrue(handler(try keyDown("y")))

        XCTAssertEqual(board.string(forType: .string), "❯ seq 1 3\n1")
    }

    func test_ztScrollsTheCursorLineToTheTop() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "❯ distinctive"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "precondition")

        XCTAssertTrue(handler(try keyDown("z")))
        XCTAssertTrue(handler(try keyDown("t")))

        XCTAssertEqual(surface.scrolls, [.lines(11)], "eleven rows of buffer move under it")
        var scrolled = Array(repeating: "", count: 24)
        scrolled[0] = "❯ distinctive"
        surface.rows = scrolled
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 165))

        XCTAssertEqual(controller.scrollMode.cursorRow, 0, "the band followed the line up")
    }

    /// At the end of the buffer nothing is below to scroll into view, so the scroll is clamped and
    /// the line never arrives. A band moved on faith would name a row it is not on.
    func test_aClampedPlaceLeavesTheBandOnItsLine() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("z")))
        XCTAssertTrue(handler(try keyDown("t")))
        // Nothing moved, so no scroll report follows and nothing re-places the band.

        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "still on the line it was reading")
    }

    /// The middle of the screen, not half of the last written row: on a half-filled pane those are
    /// different rows, and only one of them is the middle of anything.
    func test_zzCentresInTheViewportNotInWhatIsWritten() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "precondition")

        XCTAssertTrue(handler(try keyDown("z")))
        XCTAssertTrue(handler(try keyDown("z")))

        XCTAssertEqual(surface.scrolls, [], "row 11 is already the middle of a 24 row grid")
    }

    func test_fLandsOnTheCharacterAndTStopsShortOfIt() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "alpha beta gamma"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("f")))
        XCTAssertTrue(handler(try keyDown("g")), "the target, not the gg prefix")
        XCTAssertEqual(controller.scrollMode.cursor.column, 11)

        XCTAssertTrue(handler(try keyDown("0")))
        XCTAssertTrue(handler(try keyDown("t")))
        XCTAssertTrue(handler(try keyDown("g")))
        XCTAssertEqual(controller.scrollMode.cursor.column, 10, "one cell short")
    }

    func test_semicolonRepeatsAFindAndCommaReversesIt() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "a.b.c.d"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("f")))
        XCTAssertTrue(handler(try keyDown(".")))
        XCTAssertEqual(controller.scrollMode.cursor.column, 1)

        XCTAssertTrue(handler(try keyDown(";")))
        XCTAssertEqual(controller.scrollMode.cursor.column, 3)

        XCTAssertTrue(handler(try keyDown(",")))
        XCTAssertEqual(controller.scrollMode.cursor.column, 1, "the same find, the other way")
    }

    func test_repeatingATillFindClearsTheCellItIsAlreadySittingOn() throws {
        // A `t` parks one cell short of its target, so repeating from there finds that same target
        // and the cursor never moves. Vim special-cases it; so does this.
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "abc.def.ghi"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("t")))
        XCTAssertTrue(handler(try keyDown(".")))
        XCTAssertEqual(controller.scrollMode.cursor.column, 2, "one short of the first dot")

        XCTAssertTrue(handler(try keyDown(";")))

        XCTAssertEqual(controller.scrollMode.cursor.column, 6, "one short of the second, not stuck")
    }

    // MARK: counts, through the real handler

    func test_aCountCarriesTheCursorThatManyRows() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "precondition: the prompt row")

        XCTAssertTrue(handler(try keyDown("9")))
        XCTAssertTrue(handler(try keyDown("k")))

        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "nine rows up in one keystroke")
    }

    func test_aTwoDigitCountAccumulatesRatherThanRunningTwice() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("1")))
        XCTAssertTrue(handler(try keyDown("0")), "the second key of `10`, not a jump to column 0")
        XCTAssertTrue(handler(try keyDown("k")))

        XCTAssertEqual(controller.scrollMode.cursorRow, 1)
    }

    func test_aCountRunsOutAtTheEdge_movingTheCursorThenTheBuffer() throws {
        // Vim clamps and beeps. Here the cursor takes what it can and the buffer takes the rest, so
        // nothing the reader asked for is silently thrown away.
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("1")))
        XCTAssertTrue(handler(try keyDown("5")))
        XCTAssertTrue(handler(try keyDown("k")))  // eleven rows of room, fifteen asked for

        XCTAssertEqual(controller.scrollMode.cursorRow, 0)
        XCTAssertEqual(surface.scrolls, [.lines(-4)], "the four rows the cursor could not take")
    }

    /// Vim's rule. Without it the last half page of a buffer is unreachable by paging: the viewport
    /// stops, the cursor is left mid-screen, and only `gg` or a run of `k` finishes the journey.
    func test_aPageMoveAgainstTheEndCarriesTheCursorToIt() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)
        // Resting at the top of the buffer: nothing above to scroll into view.
        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 100, offset: 0, viewport: 24))

        XCTAssertTrue(handler(try keyDown("u", flags: .control)))

        XCTAssertEqual(surface.scrolls, [], "the buffer had nowhere to go")
        XCTAssertEqual(controller.scrollMode.cursorRow, 0, "so the cursor made the trip")
    }

    func test_aPageMoveAgainstTheBottomLandsOnTheLastWrittenRow() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)
        for _ in 0..<9 { XCTAssertTrue(handler(try keyDown("k"))) }
        // Resting at the bottom: `linesBelow` is zero.
        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 24, offset: 0, viewport: 24))

        XCTAssertTrue(handler(try keyDown("d", flags: .control)))

        XCTAssertEqual(surface.scrolls, [])
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "the prompt, not row 23's empty space")
    }

    func test_aCountReachesTheControlPageKeys() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("3")))
        XCTAssertTrue(handler(try keyDown("d", flags: .control)))

        XCTAssertEqual(surface.scrolls, [.pageFraction(1.5)], "three half pages in one scroll")
    }

    func test_aCountIsSpentByTheMotionItPrefixes() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("3")))
        XCTAssertTrue(handler(try keyDown("k")))
        XCTAssertEqual(controller.scrollMode.cursorRow, 8)
        XCTAssertTrue(handler(try keyDown("k")))

        XCTAssertEqual(controller.scrollMode.cursorRow, 7, "one row, not another three")
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
        surface.rows = Self.slidDown(surface.rows, by: 3)
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
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

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

    func test_aResizeKeepsTheBandOnTheLineItWasReading() throws {
        // The bug: the cursor is a viewport row number, a resize rewraps the text under it, and
        // nothing re-numbered it. The band kept its row and the reader's line moved out from under.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the seq command")

        surface.delegate?.surfaceGridDidReflow(surface)
        // The reflow the resize asked for: a taller window fits three more rows, so the text slid
        // down into them. Sent after the event, as libghostty does it: the grid resizes
        // synchronously and the buffer rewraps on its IO thread afterwards.
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 5, "the band follows the line, not the row number")
    }

    func test_aResizeGivesTheAnchorBack() throws {
        // Same rule the font step follows. Only the cursor can be found again by content; the
        // anchor is a bare row index, so a selection kept across a resize covers other words.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        surface.delegate?.surfaceGridDidReflow(surface)
        _ = handler(try keyDown("y"))

        XCTAssertNil(board.string(forType: .string))
    }

    func test_aReflowFromAnotherPaneLeavesTheModeAlone() throws {
        // Every surface in the window reports its own reflow, and a divider drag reflows one side
        // only. Unscoped, the untouched pane's mode dropped its selection and re-read its rows.
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)
        let other = RecordingSurface()

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        controller.scrollMode.reportReflow(from: other)
        _ = handler(try keyDown("y"))

        XCTAssertNotNil(
            board.string(forType: .string), "nothing this mode is driving reflowed")
    }

    func test_aResizeAfterAPageMoveDoesNotChaseTheLineTheReaderScrolledAwayFrom() throws {
        // A page move slides the viewport under a cursor that stayed put, so the line the band is
        // on changes with no cursor move to record it. The row read on that path describes the old
        // screen by the code's own admission, so remembering it left a resize anchoring to a line
        // the reader had already scrolled past, and the band chased it across the pane.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the seq command")

        _ = handler(try keyDown("d", flags: .control))  // page down: the buffer moves, the band does not
        // The frame that serves it: the seq command is now six rows further down the viewport.
        var scrolled = Array(repeating: "", count: 24)
        scrolled[8] = "❯ seq 1 3"
        surface.rows = scrolled
        surface.delegate?.surfaceGridDidReflow(surface)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 2, "the band stays; that line is not the one it is on")
    }

    func test_aShrinkThatCutsTheCursorsRowStillFindsTheLine() throws {
        // The grid changes shape before the reflow is announced, so a band sitting in the rows the
        // resize cut names a row the backend will not read by the time anyone asks. Read at that
        // moment it came back empty, the anchor was never armed, and the band silently stopped
        // following — the same failure this whole mechanism exists to prevent, in the one direction
        // nothing covered.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[20] = "❯ make test"  // the reader's line, low enough to be cut
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 20, "precondition: opened on that line")
        // Output lands before the resize, which drops the row cache. Without that the cache still
        // holds row 20's text and hides the bug behind a lucky hit.
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))

        // The resize lands: six rows fewer, and row 20 is past the bottom edge from here on.
        surface.cellMetrics = TerminalCellMetrics(
            columns: 80, rows: 18, cellWidth: 8, cellHeight: 16, gridInset: 2)
        surface.delegate?.surfaceGridDidReflow(surface)
        var reflowed = Array(repeating: "", count: 24)
        reflowed[14] = "❯ make test"
        surface.rows = reflowed
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 14, "the line was remembered before the grid moved")
    }

    func test_aReportLongAfterTheReflowLeavesTheBandAlone() throws {
        // libghostty emits a scrollbar only from a draw and only when the value differs, so a
        // resize that rewraps nothing reports nothing at all. Left armed, the anchor fired on
        // whatever came next: a background process printing one line minutes later moved the band
        // off the row the reader had been sitting on without touching the keyboard.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        var clock = ContinuousClock.now
        controller.scrollMode.now = { clock }
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the seq command")

        surface.delegate?.surfaceGridDidReflow(surface)
        clock = clock.advanced(by: .seconds(60))  // the report that never came, and then output
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 2, "that report belongs to a different event")
    }

    func test_aNarrowerWindowFindsTheLineByTheFragmentLeftOfIt() throws {
        // A width change rewraps, and `text(viewportRow:)` reads one row's cells, so no row holds
        // the whole of what was remembered. Matching on exact text alone found nothing here, the
        // band held its row, and the reader watched their line slide out from under it.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let long = "❯ tail -f /var/log/system.log | grep -i kernel | less -R"
        surface.rows[2] = long
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the long command")

        surface.delegate?.surfaceGridDidReflow(surface)
        // The rewrap: the line no longer fits, so it takes two rows and row 2 holds neither whole.
        var rewrapped = Array(repeating: "", count: 24)
        rewrapped[6] = "❯ tail -f /var/log/system.log | grep"
        rewrapped[7] = "-i kernel | less -R"
        rewrapped[8] = "❯"
        surface.rows = rewrapped
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 6, "the row holding the front of the line it was on")
    }

    func test_aWiderWindowFindsTheLineThatAbsorbedTheFragment() throws {
        // The same reflow the other way: two rows merge back into one, so the remembered text is
        // now a prefix of the row rather than the row being a prefix of it.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[2] = "❯ tail -f /var/log/system.log | grep"
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        surface.delegate?.surfaceGridDidReflow(surface)
        var rewrapped = Array(repeating: "", count: 24)
        rewrapped[4] = "❯ tail -f /var/log/system.log | grep -i kernel | less -R"
        surface.rows = rewrapped
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(controller.scrollMode.cursorRow, 4)
    }

    func test_theBufferMovingUnderASelection_stopsPaintingIt() throws {
        // The anchor is given back whenever the rows move, but the overlay holds the rects it was
        // last handed: the highlight stayed painted over rows it no longer covered.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("v")))
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))
        XCTAssertNotNil(
            panel.scrollCursorForTesting.state?.selection, "precondition: the rects are up")

        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 160))

        XCTAssertNil(controller.scrollMode.selection, "the anchor comes back when the rows move")
        XCTAssertNil(
            panel.scrollCursorForTesting.state?.selection, "and the overlay stops painting it")
    }

    func test_aWiderWindowFindsTheLineThatSwallowedAContinuationRow() throws {
        // A cursor on the SECOND visual row of a wrapped line holds a suffix, not a prefix, so
        // widening puts the remembered text mid-row and both the exact and prefix passes miss.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[2] = "-i kernel | less -R --quit-if-one-screen"
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the continuation row")

        surface.delegate?.surfaceGridDidReflow(surface)
        var rewrapped = Array(repeating: "", count: 24)
        rewrapped[5] = "❯ tail -f /var/log/system.log | grep -i kernel | less -R --quit-if-one-screen"
        surface.rows = rewrapped
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(controller.scrollMode.cursorRow, 5, "the row that absorbed the continuation")
    }

    func test_aContainedMatchStillNeedsEnoughSharedText() throws {
        // Containment matches far more loosely than the passes above it, so the same floor applies:
        // a short run inside an unrelated row must not drag the band to it.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[2] = "kernel"  // 6 characters, under minimumFragmentMatch
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition")

        surface.delegate?.surfaceGridDidReflow(surface)
        var rewrapped = Array(repeating: "", count: 24)
        rewrapped[7] = "❯ tail -f /var/log/kernel.log | less"
        surface.rows = rewrapped
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "six shared characters is not a re-find")
    }

    func test_aPromptSigilIsNotEnoughSharedTextToMoveTheBand() throws {
        // Every line on screen starts with the prompt. Without a floor on how much a fragment has
        // to share, a reflow that lost the line entirely anchored the band to whichever bare
        // prompt sat nearest, which is a jump to an unrelated row dressed up as a re-find.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[2] = "❯ seq 1 3"
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        surface.delegate?.surfaceGridDidReflow(surface)
        var scrolledAway = Array(repeating: "", count: 24)
        scrolledAway[5] = "❯"  // shares the sigil and nothing else
        surface.rows = scrolledAway
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "nothing worth calling the same line")
    }

    func test_aDragOfSeveralReflowsKeepsTheLineTheReaderChose() throws {
        // A drag fires one reflow per boundary it crosses and can produce no scroll report at all
        // along the way, so every one of them re-arms the anchor. Only a cursor move changes which
        // line the reader is on: if a geometry refresh also re-reads the row, the second reflow
        // records whatever the first one's rewrap left there and the third anchors to it.
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the seq command")

        surface.delegate?.surfaceGridDidReflow(surface)
        surface.rows = Self.slidDown(surface.rows, by: 3)  // that reflow lands, mid-drag
        surface.delegate?.surfaceGridDidReflow(surface)
        surface.delegate?.surfaceGridDidReflow(surface)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 5, "the line the reader was on, not the blank it left")
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

    /// A viewport whose text slid down by `count` rows, which is what a reflow into a grid that
    /// fits more rows looks like. The rows pushed past the bottom are gone; the ones opened at the
    /// top are blank.
    private static func slidDown(_ rows: [String], by count: Int) -> [String] {
        var reflowed = Array(repeating: "", count: rows.count)
        for (offset, text) in rows.enumerated() where offset + count < rows.count {
            reflowed[offset + count] = text
        }
        return reflowed
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
