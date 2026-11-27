import AppKit
import XCTest

@testable import TerminalKit

@testable import ZenTerm

// Scroll mode over a live libghostty surface, keys sent through `KeyInterceptor` and the window.
final class ScrollModeGridTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var surfaces: [GhosttySurface] = []
    private var interceptor: KeyInterceptor?
    private let board = NSPasteboard(name: NSPasteboard.Name("zenterm-scroll-mode-grid-\(UUID().uuidString)"))

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = GhosttySurface()
            self?.surfaces.append(surface)
            return surface
        }
    }

    override func tearDownWithError() throws {
        if let controller {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controller = nil
        interceptor = nil
        surfaces.forEach { $0.terminate() }
        surfaces = []
        board.releaseGlobally()
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func pane(
        running script: String, until marker: String
    ) throws -> (controller: WindowController, surface: GhosttySurface, grid: TerminalGrid) {
        let (c, surface, grid) = try mount(running: script)
        waitUntil(row(grid, marker) != nil, "\(marker) printed", timeout: 15)
        return (c, surface, grid)
    }

    // A surface is born at a default size and rewraps once the pane's frame reaches the grid, so this prints after.
    private func settledPane(
        running script: String, until marker: String
    ) throws -> (controller: WindowController, surface: GhosttySurface, grid: TerminalGrid) {
        let (c, surface, grid) = try mount(running: "stty -echo; read columns; " + script)
        let host = try XCTUnwrap(surface.view as? GhosttyHostView)
        let width = { grid.row(grid.viewportTop)?.cells.count }
        waitUntil(
            host.lastPushedFrameForTesting == host.bounds.size && width() == surface.cellMetrics?.columns,
            "the grid to take the pane's width", timeout: 5)
        surface.paste(String(try XCTUnwrap(width())))
        surface.submit()
        waitUntil(row(grid, marker) != nil, "\(marker) printed", timeout: 15)
        return (c, surface, grid)
    }

    private func mount(
        running script: String
    ) throws -> (controller: WindowController, surface: GhosttySurface, grid: TerminalGrid) {
        var config = GeneralConfig.builtIn
        config.shell = "/bin/sh"
        config.shellArgs = ["-c", script + "; exec sleep 600"]
        GeneralConfig.setCurrentForTesting(config)
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        let keys = KeyInterceptor()
        keys.onKeyToFocus = { [unowned c] in c.keyReachedFocus($0) }
        c.keyModeHost = keys
        interceptor = keys
        c.mountAndStart()
        c.window.orderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        controller = c
        c.scrollMode.yankPasteboard = board
        let surface = try XCTUnwrap(surfaces.first)
        try XCTSkipIf(!surface.isStarted, "ghostty_surface_new failed")
        return (c, surface, try XCTUnwrap(surface.grid))
    }

    // A line exactly as wide as the grid, so any narrowing wraps it onto a second row.
    private let fullRow = "printf '%*s\\n' \"$columns\" '' | tr ' ' x"

    private func press(_ characters: String, shift: Bool = false, control: Bool = false, keyCode: UInt16 = 0) throws {
        let c = try XCTUnwrap(controller)
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if control { flags.insert(.control) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: shift ? characters.lowercased() : characters, isARepeat: false,
                keyCode: keyCode))
        if let routed = try XCTUnwrap(interceptor).route(event) { c.window.sendEvent(routed) }
    }

    private func type(_ keys: String) throws {
        for key in keys { try press(String(key)) }
    }

    private func text(_ grid: TerminalGrid, _ index: Int) -> String {
        (grid.row(index)?.cells.map { $0.text.isEmpty && $0.width > 0 ? " " : $0.text }.joined() ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func row(_ grid: TerminalGrid, _ line: String) -> Int? {
        (0..<grid.rowCount).last { text(grid, $0) == line }
    }

    private func cursorText(_ grid: TerminalGrid) throws -> String {
        text(grid, try XCTUnwrap(controller?.scrollMode.cursor?.row))
    }

    private func enterOn(_ grid: TerminalGrid, line: String) throws {
        let c = try XCTUnwrap(controller)
        c.handle(.toggleScrollMode)
        c.scrollMode.land(on: TerminalGridPoint(row: try XCTUnwrap(row(grid, line)), column: 0))
    }

    func test_theModeStartsOnTheShellCursor() throws {
        let (c, _, grid) = try pane(running: "printf 'one\\ntwo\\nlast'", until: "last")

        try pressChord("s", [.command, .shift], keyCode: 1, in: c)

        XCTAssertEqual(c.scrollMode.cursor, grid.cursorPoint)
    }

    func test_hAtAnEmptyPromptStepsOntoThePrompt() throws {
        let (c, _, grid) = try pane(running: "printf 'ab> '", until: "ab>")
        try pressChord("s", [.command, .shift], keyCode: 1, in: c)
        XCTAssertEqual(c.scrollMode.cursor?.column, 4, "precondition: on the shell cursor, past the written text")

        try press("h")

        XCTAssertEqual(c.scrollMode.cursor, TerminalGridPoint(row: try XCTUnwrap(row(grid, "ab>")), column: 2))
    }

    func test_backwardFindAtAnEmptyPromptReachesTheTextBeforeIt() throws {
        let (c, _, _) = try pane(running: "printf 'ab> '", until: "ab>")
        try pressChord("s", [.command, .shift], keyCode: 1, in: c)

        try press("F", shift: true)
        try press("a")

        XCTAssertEqual(c.scrollMode.cursor?.column, 0)
    }

    func test_theCursorStaysOnItsTextThroughOutputAndTheRewrapAfterIt() throws {
        let (c, surface, grid) = try settledPane(
            running: "seq 1 20; \(fullRow); echo READ-HERE; sleep 1; seq 1000 1300; echo DONE", until: "READ-HERE")
        try enterOn(grid, line: "READ-HERE")
        let before = try XCTUnwrap(c.scrollMode.cursor?.row)
        waitUntil(row(grid, "DONE") != nil, "the burst printed", timeout: 15)
        let columns = surface.cellMetrics?.columns

        c.window.setContentSize(NSSize(width: 600, height: 600))
        c.window.contentView?.layoutSubtreeIfNeeded()
        waitUntil(surface.cellMetrics?.columns != columns, "the grid narrowed")
        waitUntil(row(grid, "READ-HERE") != before, "the rewrap renumbered the rows", timeout: 5)

        XCTAssertEqual(try cursorText(grid), "READ-HERE")
    }

    func test_aSelectionSurvivesAResizeThatRewrapsTheLinesAboveIt() throws {
        let (c, surface, grid) = try settledPane(
            running: "\(fullRow); echo keep this text; echo END", until: "END")
        try enterOn(grid, line: "keep this text")
        try press("v")
        try press("$")
        XCTAssertEqual(surface.copySelection(), "keep this text", "precondition")
        let columns = surface.cellMetrics?.columns

        let before = row(grid, "keep this text")
        c.window.setContentSize(NSSize(width: 600, height: 600))
        c.window.contentView?.layoutSubtreeIfNeeded()
        waitUntil(surface.cellMetrics?.columns != columns, "the grid narrowed")
        waitUntil(row(grid, "keep this text") != before, "the rewrap renumbered the rows", timeout: 5)

        XCTAssertEqual(surface.copySelection(), "keep this text", "the selection followed its text")
        try press("y")
        XCTAssertEqual(board.string(forType: .string), "keep this text")
    }

    func test_aYankReachesPastTheTopOfTheScreen() throws {
        let (c, _, grid) = try pane(running: "seq 1 300", until: "300")
        c.handle(.toggleScrollMode)
        let top = grid.viewportTop
        let rows = try XCTUnwrap(c.focusedSurfaceForTesting?.cellMetrics?.rows)

        try press("v")
        try type("\(rows + 20)k")
        XCTAssertLessThan(grid.viewportTop, top, "the screen followed the cursor up")
        try press("y")

        let yanked = try XCTUnwrap(board.string(forType: .string)).split(separator: "\n").map(String.init)
        XCTAssertEqual(yanked.first, String(300 - rows - 19), "the first line the cursor reached, off the old screen")
        XCTAssertEqual(yanked.last, "300")
    }

    func test_shiftVTakesTheWholeWrappedLine() throws {
        let long = String(repeating: "w", count: 200)
        let (c, surface, grid) = try pane(running: "echo \(long); echo after", until: "after")
        let afterRow = try XCTUnwrap(row(grid, "after"))
        XCTAssertEqual(grid.row(afterRow - 1)?.continues, true, "precondition: the line wraps")
        c.handle(.toggleScrollMode)
        c.scrollMode.land(on: TerminalGridPoint(row: afterRow - 1, column: 0))

        try press("V", shift: true)
        XCTAssertEqual(surface.copySelection(), long, "every row of the line, not only the one under the cursor")
        try press("y")

        XCTAssertEqual(board.string(forType: .string), long)
    }

    func test_yyTakesTheWholeWrappedLine() throws {
        let long = String(repeating: "q", count: 200)
        let (c, _, grid) = try settledPane(running: "echo \(long); echo after", until: "after")
        c.handle(.toggleScrollMode)
        let start = try XCTUnwrap((0..<grid.rowCount).first { text(grid, $0).hasPrefix("qqq") })
        XCTAssertEqual(grid.row(start)?.wraps, true, "precondition: the line wraps")
        c.scrollMode.land(on: TerminalGridPoint(row: start, column: 0))

        try type("yy")

        XCTAssertEqual(board.string(forType: .string), long)
    }

    func test_lStepsOverAWideCharacterInOne() throws {
        let (c, _, grid) = try pane(running: "printf 'a\\346\\274\\242b\\n'", until: "a漢b")
        try enterOn(grid, line: "a漢b")
        let panel = try XCTUnwrap(c.focusedPanelForTesting)

        try press("l")
        XCTAssertEqual(c.scrollMode.cursor?.column, 1)
        XCTAssertEqual(panel.scrollCursorForTesting.state?.cursor?.columns, 1...2, "drawn over both cells")
        XCTAssertEqual(panel.scrollCursorForTesting.state?.cursor?.glyph, "漢")
        try press("l")

        XCTAssertEqual(c.scrollMode.cursor?.column, 3, "the b, past the wide character's second cell")
    }

    func test_bracesStopAtMarkedPromptsRatherThanBlankLines() throws {
        let prompt = { (command: String) in "\\033]133;A\\007$ \\033]133;B\\007\(command)\\n\\033]133;C\\007" }
        let (c, _, grid) = try pane(
            running: "printf '\(prompt("first"))out1\\n\\nout1b\\n\(prompt("second"))out2\\n'", until: "out2")
        try enterOn(grid, line: "out2")

        try press("{", shift: true)
        XCTAssertEqual(try cursorText(grid), "$ second")
        try press("{", shift: true)

        XCTAssertEqual(try cursorText(grid), "$ first", "past the blank line inside the first command's output")
    }

    func test_bracesStopAtBlankLinesWithoutShellIntegration() throws {
        let (c, _, grid) = try pane(running: "printf 'a1\\na2\\n\\nb1\\nb2\\n'", until: "b2")
        try enterOn(grid, line: "b2")

        try press("{", shift: true)

        XCTAssertEqual(c.scrollMode.cursor?.row, try XCTUnwrap(row(grid, "b1")) - 1)
    }

    func test_aClickThatClearsTheSelectionEndsTheMode() throws {
        let (c, _, grid) = try pane(running: "echo hello", until: "hello")
        try enterOn(grid, line: "hello")
        try press("v")
        try press("l")
        waitUntil(grid.selectionBounds != nil, "the selection")

        grid.setSelection(nil)

        waitUntil(!c.scrollMode.isActive, "the mode ended")
    }

    func test_theModesOwnSelectionChangesKeepItUp() throws {
        let (c, _, grid) = try pane(running: "echo hello there", until: "hello there")
        try enterOn(grid, line: "hello there")

        try press("v")
        try press("w")
        try press("\u{1b}", keyCode: 53)
        try press("v")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(c.scrollMode.isActive, "every set and clear above reported back, and none was a click")
        XCTAssertNotNil(grid.selectionBounds)
    }

    func test_enteringOverAMouseSelectionKeepsItAndStartsOnIt() throws {
        let (c, surface, grid) = try pane(running: "echo alpha beta gamma", until: "alpha beta gamma")
        let line = try XCTUnwrap(row(grid, "alpha beta gamma"))
        grid.setSelection(TerminalGridPoint(row: line, column: 6)...TerminalGridPoint(row: line, column: 9))

        c.handle(.toggleScrollMode)

        XCTAssertEqual(c.scrollMode.cursor, TerminalGridPoint(row: line, column: 6))
        XCTAssertEqual(surface.copySelection(), "beta")
        try press("y")
        XCTAssertEqual(board.string(forType: .string), "beta", "the kept selection is the mode's to yank")
    }

    func test_leavingTheModeClearsItsSelection() throws {
        let (c, _, grid) = try pane(running: "echo hello", until: "hello")
        try enterOn(grid, line: "hello")
        try press("v")
        try press("l")

        try press("q")

        XCTAssertFalse(c.scrollMode.isActive)
        XCTAssertNil(grid.selectionBounds)
    }

    func test_findLandsOnTheMatchGhosttySelectedAmongSeveralOnScreen() throws {
        let (c, _, grid) = try pane(
            running: "echo 'NEEDLE one'; echo 'xx NEEDLE two'; echo 'NEEDLE three'", until: "NEEDLE three")
        c.handle(.toggleSearch)
        c.search.typeForTesting("NEEDLE")
        waitUntil(c.search.isActive, "search open")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        c.search.step(.next)
        c.search.step(.next)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        c.handle(.toggleScrollMode)
        waitUntil(c.scrollMode.cursor?.column == 3, "the cursor on the selected match")

        XCTAssertEqual(try cursorText(grid), "xx NEEDLE two", "the second newest, where two steps took it")
        try press("n")
        waitUntil((try? cursorText(grid)) == "NEEDLE one", "n stepped to the older match")
    }

    func test_findOpensOnTheModesSelection() throws {
        let (c, _, grid) = try pane(running: "echo an error happened", until: "an error happened")
        try enterOn(grid, line: "an error happened")
        try type("wve")

        c.handle(.toggleSearch)

        XCTAssertEqual(c.focusedPanelForTesting?.findFieldForTesting?.needle, "error")
    }

    private func readout() throws -> String? {
        try XCTUnwrap(controller?.focusedPanelForTesting?.shownHeaderForTesting).readoutForTesting
    }

    func test_theHeaderReadsTheCursorsRowAndColumn_andFollowsAMotion() throws {
        let (_, _, grid) = try pane(running: "printf 'one\\ntwo\\nlast\\n'", until: "last")
        let two = try XCTUnwrap(row(grid, "two"))
        try enterOn(grid, line: "two")
        XCTAssertEqual(try readout(), "\(two + 1):1")

        try press("l")
        XCTAssertEqual(try readout(), "\(two + 1):2")
        try press("j")

        XCTAssertEqual(try readout(), "\(two + 2):2")
    }

    func test_vOnOneRowCountsCharacters_andAcrossRowsCountsLines() throws {
        let (_, _, grid) = try pane(running: "echo hello there; echo second line", until: "second line")
        try enterOn(grid, line: "hello there")

        try press("v")
        XCTAssertEqual(try readout(), "1 char")
        try press("e")
        XCTAssertEqual(try readout(), "5 chars")
        try press("j")

        XCTAssertEqual(try readout(), "2 lines")
    }

    func test_shiftVCountsEachRowOfAWrappedLine() throws {
        let long = String(repeating: "w", count: 200)
        let (c, _, grid) = try settledPane(running: "echo \(long); echo after", until: "after")
        let afterRow = try XCTUnwrap(row(grid, "after"))
        XCTAssertEqual(grid.row(afterRow - 1)?.continues, true, "precondition: the line wraps")
        let first = try XCTUnwrap((0..<grid.rowCount).first { text(grid, $0).hasPrefix("www") })
        c.handle(.toggleScrollMode)
        c.scrollMode.land(on: TerminalGridPoint(row: first, column: 0))

        try press("V", shift: true)

        XCTAssertGreaterThan(afterRow - first, 1, "premise: more than one row")
        XCTAssertEqual(try readout(), "\(afterRow - first) lines")
    }

    func test_aCopyConfirmsWhatItTook_untilTheNextKey() throws {
        let (_, _, grid) = try pane(running: "echo hello there; echo second line", until: "second line")
        let hello = try XCTUnwrap(row(grid, "hello there"))
        try enterOn(grid, line: "hello there")

        try type("vey")
        XCTAssertEqual(try readout(), "Copied 5 characters")
        try press("l")
        XCTAssertEqual(try readout(), "\(hello + 1):6", "the next key gives the position back")

        try type("vjy")
        XCTAssertEqual(try readout(), "Copied 2 lines")
        try type("yy")
        XCTAssertEqual(try readout(), "Copied 1 line")
        try type("vy")
        XCTAssertEqual(try readout(), "Copied 1 character")
        try press("2")

        XCTAssertEqual(try readout(), "\(hello + 2):6", "a count is a key too")
    }

    func test_findOverTheModeTakesTheReadoutsPlace_untilItCloses() throws {
        let (c, _, grid) = try pane(running: "echo hello", until: "hello")
        let hello = try XCTUnwrap(row(grid, "hello"))
        try enterOn(grid, line: "hello")

        c.handle(.toggleSearch)
        XCTAssertNotNil(c.focusedPanelForTesting?.findFieldForTesting)
        XCTAssertNil(try readout())
        c.search.end()

        XCTAssertEqual(try readout(), "\(hello + 1):1")
    }
}
