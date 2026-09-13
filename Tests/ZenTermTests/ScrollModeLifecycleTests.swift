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

    func test_enteringOverASelection_landsOnItsFirstCell() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.selectionOrigin = TerminalViewportCell(row: 2, column: 4)

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(controller.scrollMode.cursorRow, 2)
        XCTAssertEqual(controller.scrollMode.cursor.column, 4)
    }

    func test_enteringOverASelectionOnAWideRowLandsOnTheCharacterNotTheOffset() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[3] = "你ab"
        surface.selectionOrigin = TerminalViewportCell(row: 3, column: 2)

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(controller.scrollMode.cursor.column, 1, "offset 1 is the `a`")
        let state = try XCTUnwrap(panel.scrollCursorForTesting.state)
        XCTAssertEqual(state.cursorCells, 2...2, "and it is drawn on the cell the reader selected")
    }

    func test_enteringWithNoSelection_stillOpensOnTheLastWrittenRow() throws {
        let controller = makeWindow()

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "the fixture's prompt row")
    }

    func test_theEntryRowIsReadBeforeTheHeaderBlanksThePrompt() throws {
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
        repainted[9] = "❯ echo hello"
        surface.rows = repainted
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(controller.scrollMode.cursorRow, 9, "the band followed the prompt")
    }

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

        XCTAssertEqual(surface.scrolls, [.lines(12), .lines(-12), .bottom])
    }

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

    func test_aMotionReadsTheScreenAgainRatherThanTheLastKeystrokesCopy() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        let surface = try XCTUnwrap(spawned.first)
        XCTAssertTrue(handler(try keyDown("L", unshifted: "l", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "precondition: the prompt row")

        surface.rows[12] = "❯ redrawn"

        XCTAssertTrue(handler(try keyDown("L", unshifted: "l", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 12, "the screen it has now, not the cached one")
    }

    func test_landingOnAMatchReadsTheViewportItLandedOn() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        let surface = try XCTUnwrap(spawned.first)
        XCTAssertTrue(handler(try keyDown("L", unshifted: "l", flags: .shift)))

        surface.rows[12] = "❯ rg needle"
        controller.scrollMode.land(on: ScrollCell(row: 12, column: 10))

        XCTAssertEqual(controller.scrollMode.cursor.column, 10, "not clamped to the old row's end")
    }

    func test_theEndOfLineReadsTheRowAgainAfterARepaint() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        let surface = try XCTUnwrap(spawned.first)
        XCTAssertTrue(handler(try keyDown("$", unshifted: "4", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursor.column, 0, "precondition: a one-character prompt")

        surface.rows[11] = "❯ ls -la"

        XCTAssertTrue(handler(try keyDown("$", unshifted: "4", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursor.column, 7)
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

        for _ in 0..<3 { XCTAssertTrue(handler(try keyDown("k"))) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 8, "precondition")
        XCTAssertTrue(handler(try keyDown("*", unshifted: "8", flags: .shift)))

        XCTAssertEqual(panel.findBarForTesting?.needle, "hi")
    }

    func test_aYankPastAWideCharacterTakesTheWholeOfIt() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "你好 world"
        let board = NSPasteboard(name: NSPasteboard.Name("zenterm-yank-\(UUID().uuidString)"))
        controller.handle(.toggleScrollMode)
        controller.scrollMode.yankPasteboard = board
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("0")))
        XCTAssertTrue(handler(try keyDown("v")))
        XCTAssertTrue(handler(try keyDown("$", unshifted: "4", flags: .shift)))
        XCTAssertTrue(handler(try keyDown("y")))

        XCTAssertEqual(board.string(forType: .string), "你好 world", "not `你好 worl`")
    }

    func test_aSelectionToTheEndOfTheRowStopsAtTheText() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "你好 world"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("0")))
        XCTAssertTrue(handler(try keyDown("v")))
        XCTAssertTrue(handler(try keyDown("$", unshifted: "4", flags: .shift)))

        let state = try XCTUnwrap(panel.scrollCursorForTesting.state)
        XCTAssertEqual(state.selection?.endColumn, 9, "the row's last painted cell, not the grid's")
    }

    func test_aSelectionEndingOnATrailingWideCharacterCoversBothCells() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "ab你"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("0")))
        XCTAssertTrue(handler(try keyDown("v")))
        XCTAssertTrue(handler(try keyDown("$", unshifted: "4", flags: .shift)))

        let state = try XCTUnwrap(panel.scrollCursorForTesting.state)
        XCTAssertEqual(state.selection?.endColumn, 3, "through the far half of the wide character")
    }

    func test_theBandCoversBothCellsOfAWideCharacter() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "ab你cd"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("0")))
        for _ in 0..<2 { XCTAssertTrue(handler(try keyDown("l"))) }

        let state = try XCTUnwrap(panel.scrollCursorForTesting.state)
        XCTAssertEqual(state.cursorCells, 2...3, "the cursor outlines the whole character")
    }

    func test_aCellAfterAWideCharacterIsNotDrawnLeftOfTrue() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "ab你cd"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("0")))
        for _ in 0..<3 { XCTAssertTrue(handler(try keyDown("l"))) }

        let state = try XCTUnwrap(panel.scrollCursorForTesting.state)
        XCTAssertEqual(state.cursorCells, 4...4, "offset 3, but cell 4: 你 took two")
    }

    func test_aSelectionDraggedBackwardsStillCoversWholeCharacters() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "你好世界"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("$", unshifted: "4", flags: .shift)))
        XCTAssertTrue(handler(try keyDown("v")))
        for _ in 0..<2 { XCTAssertTrue(handler(try keyDown("h"))) }

        let state = try XCTUnwrap(panel.scrollCursorForTesting.state)
        XCTAssertEqual(
            state.selection?.startColumn, 2, "the first cell of 好, not the last of 界")
        XCTAssertEqual(state.selection?.endColumn, 7, "the last cell of 界, not the first of 好")
    }

    func test_theBandStopsAtACharacterAGapFollows() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "你" + String(repeating: RecordingSurface.unwritten, count: 8) + "12:00"
        controller.handle(.toggleScrollMode)

        let state = try XCTUnwrap(panel.scrollCursorForTesting.state)
        XCTAssertEqual(state.cursorCells, 0...1, "the 你, not it and the gap after it")
    }

    func test_aColumnInsideAGapIsTheCellItSitsOn() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "你" + String(repeating: RecordingSurface.unwritten, count: 8) + "12:00"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("0")))
        XCTAssertTrue(handler(try keyDown("l")))

        let state = try XCTUnwrap(panel.scrollCursorForTesting.state)
        XCTAssertEqual(state.cursorCells, 2...2, "cell 2, the first of the gap")
    }

    func test_yyTakesWholeRowsWithoutAVisualFirst() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let board = NSPasteboard(name: NSPasteboard.Name("zenterm-yank-\(UUID().uuidString)"))
        controller.handle(.toggleScrollMode)
        controller.scrollMode.yankPasteboard = board
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<4 { XCTAssertTrue(handler(try keyDown("k"))) }
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

        for _ in 0..<9 { XCTAssertTrue(handler(try keyDown("k"))) }
        XCTAssertTrue(handler(try keyDown("2")))
        XCTAssertTrue(handler(try keyDown("y")))
        XCTAssertTrue(handler(try keyDown("y")))

        XCTAssertEqual(board.string(forType: .string), "❯ seq 1 3\n1")
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

    func test_aCountOnAParagraphMotionRepeatsItRatherThanStriding() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "precondition: the prompt")

        XCTAssertTrue(handler(try keyDown("2")))
        XCTAssertTrue(handler(try keyDown("{", unshifted: "[", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursorRow, 6)
    }

    func test_aParagraphCountSpentAtTheTopStopsRatherThanSpinning() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("9")))
        XCTAssertTrue(handler(try keyDown("9")))
        XCTAssertTrue(handler(try keyDown("{", unshifted: "[", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursorRow, 0, "parked at the top, not still walking")
    }

    func test_aCountedTillFindClearsEachTargetItParksBeside() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[11] = "abc.def.ghi.jkl"
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("2")))
        XCTAssertTrue(handler(try keyDown("t")))
        XCTAssertTrue(handler(try keyDown(".")))

        XCTAssertEqual(controller.scrollMode.cursor.column, 6, "one short of the second dot")
    }

    func test_aPageOntoTheLastScreenReclampsWhenTheNewRowsArrive() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = (0..<24).map { "line \($0)" }
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertTrue(handler(try keyDown("G", unshifted: "g", flags: .shift)))
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 30, offset: 4, viewport: 24))

        XCTAssertTrue(handler(try keyDown("d", flags: .control)))
        var atEnd = Array(repeating: "", count: 24)
        for row in 0...5 { atEnd[row] = "tail \(row)" }
        surface.rows = atEnd
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 30, offset: 6, viewport: 24))

        XCTAssertEqual(controller.scrollMode.cursorRow, 5, "the last written row of the new screen")
    }

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
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("1")))
        XCTAssertTrue(handler(try keyDown("5")))
        XCTAssertTrue(handler(try keyDown("k")))

        XCTAssertEqual(controller.scrollMode.cursorRow, 0)
        XCTAssertEqual(surface.scrolls, [.lines(-4)], "the four rows the cursor could not take")
    }

    func test_aPageMoveAgainstTheEndCarriesTheCursorToIt() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        let handler = try XCTUnwrap(host.modeHandler)
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

        XCTAssertEqual(surface.scrolls, [.lines(36)], "three half pages of a 24 row grid")
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

    func test_theModeOpensOnTheLastWrittenLineNotTheBottomOfThePane() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 11)
    }

    func test_theEntryRowIsReadFromTheScreenNotTheShellCursor() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        var rows = Array(repeating: "", count: 24)
        rows[3] = "scrolled-back output"
        surface.rows = rows
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 3)
    }

    func test_theModeFallsBackToTheBottomRowOnAnEmptyScreen() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 23)
    }

    func test_kMovesTheCursorWithoutScrolling() throws {
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

        for _ in 0..<11 { XCTAssertTrue(handler(try keyDown("k"))) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 0)
        XCTAssertEqual(surface.scrolls, [])

        XCTAssertTrue(handler(try keyDown("k")))

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
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        XCTAssertTrue(handler(try keyDown("}", unshifted: "]", flags: .shift)))

        XCTAssertEqual(controller.scrollMode.cursorRow, 23)
    }

    func test_theMotionReadsTheScreenNotAScrollAction() throws {
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
        XCTAssertTrue(ScrollModeController.isBlank(nil))
        XCTAssertTrue(ScrollModeController.isBlank("   \t "))
        XCTAssertFalse(ScrollModeController.isBlank(" x "))
    }

    func test_aPageMoveWalksToTheMiddleBeforeItMovesTheBuffer() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        let surface = try XCTUnwrap(spawned.first)
        surface.cellMetrics = TerminalCellMetrics(
            columns: 80, rows: 25, cellWidth: 8, cellHeight: 16, gridInset: 2)
        surface.rows = (0..<25).map { "line \($0)" }
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertTrue(handler(try keyDown("g")))
        XCTAssertTrue(handler(try keyDown("g")))
        let afterGG = surface.scrolls.count
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 200, offset: 20, viewport: 25))

        XCTAssertTrue(handler(try keyDown("d", flags: .control)))

        XCTAssertEqual(surface.scrolls.count, afterGG, "the band had room to walk into")
        XCTAssertEqual(controller.scrollMode.cursorRow, 12, "the middle of a 25 row grid")

        XCTAssertTrue(handler(try keyDown("d", flags: .control)))

        XCTAssertEqual(surface.scrolls.last, .lines(12), "now the buffer moves instead")
        XCTAssertEqual(controller.scrollMode.cursorRow, 12, "and the band is parked")
    }

    func test_theCursorIsClampedToAShrunkenGrid() throws {
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
            variant: .destructive, title: "Close Pane", message: "Running work will stop.",
            confirmLabel: "Close", onConfirm: {})

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
        XCTAssertFalse(panel.isHeaderVisibleForTesting)
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
        XCTAssertTrue(panel.isHeaderVisibleForTesting)
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

    func test_outputAtTheLiveEndIsPulledBackOffTheBand() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))
        let row = controller.scrollMode.cursorRow

        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        XCTAssertEqual(surface.scrolls, [.lines(-3)], "the three rows the output pushed")
        XCTAssertEqual(controller.scrollMode.cursorRow, row, "and the band keeps its line")
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

    func test_aHeldPushStillDropsTheRowCache() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))
        XCTAssertTrue(handler(try keyDown("L", unshifted: "l", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 11, "precondition: the prompt row")

        surface.rows[12] = "❯ printed by the same burst"
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        XCTAssertTrue(handler(try keyDown("L", unshifted: "l", flags: .shift)))
        XCTAssertEqual(controller.scrollMode.cursorRow, 12, "the row the burst wrote")
    }

    func test_aRewrapAtTheLiveEndIsNotReadAsOutput() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        controller.scrollMode.refreshGeometry()
        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))

        XCTAssertEqual(surface.scrolls, [], "the rewrap put those rows there; nothing pushed a screen")
    }

    func test_aSelectionSurvivesOutputAtTheLiveEnd() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)
        let surface = try XCTUnwrap(spawned.first)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))
        XCTAssertTrue(handler(try keyDown("v")))

        surface.delegate?.surface(
            surface,
            scrollPositionDidChange: TerminalScrollPosition(total: 203, offset: 179, viewport: 24))
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertNotNil(controller.scrollMode.selection, "the screen came back to where it was")
    }

    private func enterModeForYanking(_ controller: WindowController) throws -> (
        handler: (NSEvent) -> Bool, board: NSPasteboard
    ) {
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let board = NSPasteboard(name: NSPasteboard.Name("zenterm-yank-\(UUID().uuidString)"))
        controller.scrollMode.yankPasteboard = board
        return (try XCTUnwrap(host.modeHandler), board)
    }

    private func enterModeOverNumberedRows(_ controller: WindowController) throws -> (
        surface: RecordingSurface, handler: (NSEvent) -> Bool, board: NSPasteboard
    ) {
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = (0..<24).map { "row \($0)" }
        let (handler, board) = try enterModeForYanking(controller)
        return (surface, handler, board)
    }

    func test_aCharacterSelectionYanksExactlyWhatItCovers() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("v"))
        _ = handler(try keyDown("$", unshifted: "4", flags: .shift))
        _ = handler(try keyDown("y"))

        XCTAssertEqual(board.string(forType: .string), "❯ seq 1 3")
    }

    func test_aLineSelectionYanksWholeRowsWhicheverWayItWasDragged() throws {
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

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

    func test_aScrollCarriesTheAnchorWithTheTextUnderIt() throws {
        let controller = makeWindow()
        let (surface, handler, board) = try enterModeOverNumberedRows(controller)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))

        for _ in 0..<3 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        surface.rows = Self.slidDown(surface.rows, by: 2)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 98))
        _ = handler(try keyDown("y"))

        XCTAssertEqual(board.string(forType: .string), "row 18\nrow 19\nrow 20")
    }

    func test_aScrollThatTakesTheAnchorOffScreenGivesItBack() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let (surface, handler, board) = try enterModeOverNumberedRows(controller)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        XCTAssertEqual(panel.headerContentForTesting?.title, "VISUAL: 1 LINE")

        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 130))

        XCTAssertEqual(
            panel.headerContentForTesting?.title, "SCROLL: 46 BELOW",
            "the header still reading Visual means a span nothing on screen backs")
        _ = handler(try keyDown("y"))
        XCTAssertNil(board.string(forType: .string))
    }

    func test_aScrollKeyThatMovesNothingKeepsTheSelection() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let (handler, board) = try enterModeForYanking(controller)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        for _ in 0..<14 { _ = handler(try keyDown("j")) }
        _ = handler(try keyDown("y"))

        XCTAssertNotNil(
            board.string(forType: .string),
            "nothing scrolled, so nothing reported, so the selection is still the reader's")
    }

    func test_aScrollDoesNotLeaveThePreviousScreenInTheRowCache() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<13 { _ = handler(try keyDown("j")) }
        XCTAssertEqual(surface.scrolls, [.lines(1)], "precondition: the last j asked for a scroll")

        surface.rows[23] = "❯ what the scroll brought up"
        _ = handler(try keyDown("$", unshifted: "4", flags: .shift))

        XCTAssertEqual(
            controller.scrollMode.cursor.column, 27, "the row was re-read, not served from before the scroll")
    }

    func test_aFontStepOverABlankAnchorRowGivesItBack() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let (handler, board) = try enterModeForYanking(controller)

        for _ in 0..<5 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        XCTAssertEqual(panel.headerContentForTesting?.title, "VISUAL: 1 LINE")

        controller.applySessionFontSize()

        XCTAssertEqual(panel.headerContentForTesting?.title, "SCROLL")
        _ = handler(try keyDown("y"))
        XCTAssertNil(board.string(forType: .string))
    }

    func test_aKeyBeforeTheReflowReportCallsOffTheReanchor() throws {
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

        _ = handler(try keyDown("k"))
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 1, "the row the reader chose, not the line they left")
    }

    func test_aGridThatLosesRowsKeepsTheCursorsColumn() throws {
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
        controller.applySessionFontSize()

        XCTAssertEqual(controller.scrollMode.cursorRow, 7)
        XCTAssertEqual(
            controller.scrollMode.cursor.column, 8, "the last column of row 7, not the left margin")
    }

    func test_theEndOfLineStopsAtTheLastCharacterThePaneShows() throws {
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
        let controller = makeWindow()
        let (handler, board) = try enterModeForYanking(controller)

        _ = handler(try keyDown("G", unshifted: "g", flags: .shift))
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
        controller.handle(.toggleScrollMode)
        controller.handle(.toggleScrollMode)
        let reopened = try XCTUnwrap((controller.keyModeHost as? ModeHostSpy)?.modeHandler)
        controller.scrollMode.yankPasteboard = board
        _ = reopened(try keyDown("y"))

        XCTAssertNil(board.string(forType: .string), "a reopened mode starts in normal mode")
    }

    func test_aFontStepRedrawsTheBandThoughNothingAboutItMoved() throws {
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
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 5, "the band follows the line, not the row number")
    }

    func test_aReflowThatLosesTheLineLeavesTheBandWhereItIs() throws {
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
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 5, "the band follows the line, not the row number")
    }

    func test_aResizeKeepsTheSelectionOverTheSameText() throws {
        let controller = makeWindow()
        let (surface, handler, board) = try enterModeOverNumberedRows(controller)

        for _ in 0..<3 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        for _ in 0..<2 { _ = handler(try keyDown("k")) }

        surface.delegate?.surfaceGridDidReflow(surface)
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))
        _ = handler(try keyDown("y"))

        XCTAssertEqual(board.string(forType: .string), "row 18\nrow 19\nrow 20")
    }

    func test_aReflowKeepsTheHighlightPaintedWhileTheAnchorIsUnresolved() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let (_, handler, _) = try enterModeOverNumberedRows(controller)

        for _ in 0..<3 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))

        controller.applySessionFontSize()

        XCTAssertNotNil(
            panel.scrollCursorForTesting.state?.selection, "the highlight blinked off mid-resize")
        XCTAssertEqual(panel.headerContentForTesting?.title, "VISUAL: 1 LINE")
    }

    func test_anUnresolvedSpanIsNotReadableUntilSomethingResolvesIt() throws {
        let controller = makeWindow()
        let (_, handler, _) = try enterModeOverNumberedRows(controller)

        for _ in 0..<3 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        XCTAssertNotNil(controller.scrollMode.selectedText, "precondition: readable while resolved")

        controller.applySessionFontSize()

        XCTAssertNil(
            controller.scrollMode.selectedText,
            "a read off an anchor whose row may have moved takes words nobody dragged over")
    }

    func test_aKeyAfterAReflowThatNeverReportedResolvesTheSpanRatherThanDropIt() throws {
        let controller = makeWindow()
        let (surface, handler, board) = try enterModeOverNumberedRows(controller)

        for _ in 0..<3 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        for _ in 0..<2 { _ = handler(try keyDown("k")) }

        controller.applySessionFontSize()
        surface.rows = Self.slidDown(surface.rows, by: 3)

        _ = handler(try keyDown("y"))

        XCTAssertEqual(
            board.string(forType: .string), "row 18\nrow 19\nrow 20",
            "the span covers the words it covered, re-found on the settled grid")
    }

    func test_aResizeThatCrossesTheTwoEndsGivesTheSelectionBack() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        var rows = (0..<24).map { "filler \($0)" }
        rows[20] = "❯ ls the anchor"
        rows[10] = "the cursor line"
        surface.rows = rows
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        let (handler, board) = try enterModeForYanking(controller)

        for _ in 0..<3 { _ = handler(try keyDown("k")) }
        _ = handler(try keyDown("V", unshifted: "v", flags: .shift))
        for _ in 0..<10 { _ = handler(try keyDown("k")) }

        surface.delegate?.surfaceGridDidReflow(surface)
        var reflowed = (0..<24).map { "filler \($0)" }
        reflowed[5] = "❯ ls the anchor"
        reflowed[22] = "the cursor line"
        surface.rows = reflowed
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            panel.headerContentForTesting?.title, "SCROLL: AT BOTTOM",
            "a crossed pair left up would paint a span the reader never dragged")
        _ = handler(try keyDown("y"))
        XCTAssertNil(board.string(forType: .string))
    }

    func test_aReflowFromAnotherPaneLeavesTheModeAlone() throws {
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
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler)

        for _ in 0..<9 { _ = handler(try keyDown("k")) }
        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "precondition: on the seq command")

        _ = handler(try keyDown("d", flags: .control))
        var scrolled = Array(repeating: "", count: 24)
        scrolled[8] = "❯ seq 1 3"
        surface.rows = scrolled
        surface.delegate?.surfaceGridDidReflow(surface)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertNotEqual(
            controller.scrollMode.cursorRow, 8, "row 8 holds the line the reader paged away from")
        XCTAssertEqual(
            controller.scrollMode.cursorRow, 11, "the band stays where the page put it")
    }

    func test_aShrinkThatCutsTheCursorsRowStillFindsTheLine() throws {
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[20] = "❯ make test"
        let host = ModeHostSpy()
        hosts.append(host)
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursorRow, 20, "precondition: opened on that line")
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 100))

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
        clock = clock.advanced(by: .seconds(60))
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 2, "that report belongs to a different event")
    }

    func test_aNarrowerWindowFindsTheLineByTheFragmentLeftOfIt() throws {
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
        let controller = makeWindow()
        let surface = try XCTUnwrap(spawned.first)
        surface.rows[2] = "kernel"
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
        scrolledAway[5] = "❯"
        surface.rows = scrolledAway
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(controller.scrollMode.cursorRow, 2, "nothing worth calling the same line")
    }

    func test_aDragOfSeveralReflowsKeepsTheLineTheReaderChose() throws {
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
        surface.rows = Self.slidDown(surface.rows, by: 3)
        surface.delegate?.surfaceGridDidReflow(surface)
        surface.delegate?.surfaceGridDidReflow(surface)
        surface.delegate?.surface(surface, scrollPositionDidChange: Self.position(offset: 176))

        XCTAssertEqual(
            controller.scrollMode.cursorRow, 5, "the line the reader was on, not the blank it left")
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
