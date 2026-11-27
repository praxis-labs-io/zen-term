import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

// Scroll mode's motions, selections and yanks over a recorded grid, keys sent through the mode's handler.
@MainActor
final class ScrollModeMotionAndYankTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var host = ModeHostSpy()
    private let board = NSPasteboard(name: NSPasteboard.Name("zenterm-scroll-mode-yank-\(UUID().uuidString)"))

    private final class ModeHostSpy: KeyModeHosting {
        var modeHandler: ((NSEvent) -> Bool)?
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(GeneralConfig.builtIn)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        spawned = []
        board.releaseGlobally()
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func pane(_ rows: [String]) throws -> (controller: WindowController, surface: RecordingSurface) {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        controller.mountAndStart()
        controllers.append(controller)
        host = ModeHostSpy()
        controller.keyModeHost = host
        controller.scrollMode.yankPasteboard = board
        let surface = try XCTUnwrap(spawned.first)
        surface.rows = rows
        return (controller, surface)
    }

    private func enter(_ controller: WindowController, on point: TerminalGridPoint) {
        controller.handle(.toggleScrollMode)
        controller.scrollMode.land(on: point)
    }

    private func press(_ characters: String, shift: Bool = false, keyCode: UInt16 = 0) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters,
                charactersIgnoringModifiers: shift ? characters.lowercased() : characters, isARepeat: false,
                keyCode: keyCode))
        XCTAssertTrue(try XCTUnwrap(host.modeHandler)(event), "the mode took \(characters)")
    }

    private func type(_ keys: String) throws {
        for key in keys { try press(String(key)) }
    }

    private var yanked: String? { board.string(forType: .string) }

    private func readout(_ controller: WindowController) throws -> String? {
        try XCTUnwrap(controller.focusedPanelForTesting?.shownHeaderForTesting).readoutForTesting
    }

    func test_theModeStartsOnTheShellCursor() throws {
        let (controller, surface) = try pane(["one", "two", "last"] + Array(repeating: "", count: 21))
        surface.recordingGrid.cursorPoint = TerminalGridPoint(row: 2, column: 2)

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(controller.scrollMode.cursor, TerminalGridPoint(row: 2, column: 2))
    }

    func test_aYankReachesPastTheTopOfTheScreen() throws {
        let (controller, surface) = try pane((1...300).map(String.init) + [""])
        surface.recordingGrid.viewportTop = 277
        surface.recordingGrid.cursorPoint = TerminalGridPoint(row: 300, column: 0)
        controller.handle(.toggleScrollMode)

        try press("v")
        try type("44k")
        XCTAssertEqual(surface.scrolls, [.lines(-21)], "the screen followed the cursor up")
        try press("y")

        let lines = try XCTUnwrap(yanked).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "257", "the first line the cursor reached, off the old screen")
        XCTAssertEqual(lines.last, "300")
    }

    func test_yyTakesTheWholeWrappedLine() throws {
        let (controller, surface) = try pane(
            ["before", "qqqq", "qqqq", "qq", "after"] + Array(repeating: "", count: 19))
        surface.recordingGrid.wrappingRows = [1, 2]
        enter(controller, on: TerminalGridPoint(row: 1, column: 0))

        try type("yy")

        XCTAssertEqual(yanked, "qqqqqqqqqq")
    }

    func test_bracesStopAtBlankLinesWithoutShellIntegration() throws {
        let (controller, _) = try pane(["a1", "a2", "", "b1", "b2"] + Array(repeating: "", count: 19))
        enter(controller, on: TerminalGridPoint(row: 4, column: 0))

        try press("{", shift: true)

        XCTAssertEqual(controller.scrollMode.cursor?.row, 2)
    }

    func test_aClickThatClearsTheSelectionEndsTheMode() throws {
        let (controller, surface) = try pane(["hello"] + Array(repeating: "", count: 23))
        enter(controller, on: TerminalGridPoint(row: 0, column: 0))
        try press("v")
        try press("l")
        XCTAssertNotNil(surface.recordingGrid.selectionBounds, "precondition: the mode holds a selection")

        surface.recordingGrid.setSelection(nil)
        surface.delegate?.surfaceSelectionDidChange(surface)

        XCTAssertFalse(controller.scrollMode.isActive)
    }

    func test_enteringOverAMouseSelectionKeepsItAndStartsOnIt() throws {
        let (controller, surface) = try pane(["alpha beta gamma"] + Array(repeating: "", count: 23))
        surface.recordingGrid.setSelection(TerminalGridPoint(row: 0, column: 6)...TerminalGridPoint(row: 0, column: 9))

        controller.handle(.toggleScrollMode)

        XCTAssertEqual(controller.scrollMode.cursor, TerminalGridPoint(row: 0, column: 6))
        try press("y")
        XCTAssertEqual(yanked, "beta", "the kept selection is the mode's to yank")
    }

    func test_leavingTheModeClearsItsSelection() throws {
        let (controller, surface) = try pane(["hello"] + Array(repeating: "", count: 23))
        enter(controller, on: TerminalGridPoint(row: 0, column: 0))
        try press("v")
        try press("l")

        try press("q")

        XCTAssertFalse(controller.scrollMode.isActive)
        XCTAssertNil(surface.recordingGrid.selectionBounds)
    }

    func test_findLandsOnTheMatchItSelected_andNStepsOnFromThere() throws {
        let (controller, surface) = try pane(
            ["NEEDLE one", "xx NEEDLE two", "NEEDLE three"] + Array(repeating: "", count: 21))
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("NEEDLE")
        controller.search.step(.next)
        controller.search.report(selected: 1, start: TerminalGridPoint(row: 1, column: 3), from: surface)

        controller.handle(.toggleScrollMode)
        XCTAssertEqual(controller.scrollMode.cursor, TerminalGridPoint(row: 1, column: 3))
        let steps = surface.searchSteps.count
        try press("n")
        controller.search.report(selected: 2, start: TerminalGridPoint(row: 0, column: 0), from: surface)

        XCTAssertEqual(surface.searchSteps.count, steps + 1, "n asked the engine for the next match")
        XCTAssertEqual(controller.scrollMode.cursor, TerminalGridPoint(row: 0, column: 0))
    }

    func test_theHeaderReadsTheCursorsRowAndColumn_andFollowsAMotion() throws {
        let (controller, _) = try pane(["one", "two", "last"] + Array(repeating: "", count: 21))
        enter(controller, on: TerminalGridPoint(row: 1, column: 0))
        XCTAssertEqual(try readout(controller), "2:1")

        try press("l")
        XCTAssertEqual(try readout(controller), "2:2")
        try press("j")

        XCTAssertEqual(try readout(controller), "3:2")
    }

    func test_vOnOneRowCountsCharacters_andAcrossRowsCountsLines() throws {
        let (controller, _) = try pane(["hello there", "second line"] + Array(repeating: "", count: 22))
        enter(controller, on: TerminalGridPoint(row: 0, column: 0))

        try press("v")
        XCTAssertEqual(try readout(controller), "1 character")
        try press("e")
        XCTAssertEqual(try readout(controller), "5 characters")
        try press("j")

        XCTAssertEqual(try readout(controller), "2 lines")
    }

    func test_shiftVCountsEachRowOfAWrappedLine() throws {
        let (controller, surface) = try pane(
            ["before", "wwww", "wwww", "ww", "after"] + Array(repeating: "", count: 19))
        surface.recordingGrid.wrappingRows = [1, 2]
        enter(controller, on: TerminalGridPoint(row: 1, column: 0))

        try press("V", shift: true)

        XCTAssertEqual(try readout(controller), "3 lines")
    }

    func test_aCopyConfirmsWhatItTook_untilTheNextKey() throws {
        let (controller, _) = try pane(["hello there", "second line"] + Array(repeating: "", count: 22))
        enter(controller, on: TerminalGridPoint(row: 0, column: 0))

        try type("vey")
        XCTAssertEqual(try readout(controller), "Copied 5 characters")
        try press("l")
        XCTAssertEqual(try readout(controller), "1:6", "the next key gives the position back")

        try type("vjy")
        XCTAssertEqual(try readout(controller), "Copied 2 lines")
        try type("yy")
        XCTAssertEqual(try readout(controller), "Copied 1 line")
        try type("vy")
        XCTAssertEqual(try readout(controller), "Copied 1 character")
        try press("2")

        XCTAssertEqual(try readout(controller), "2:6", "a count is a key too")
    }

    func test_aFindStepOverTheModeGivesThePositionBackAfterACopy() throws {
        let (controller, surface) = try pane(["NEEDLE one", "NEEDLE two", "end"] + Array(repeating: "", count: 21))
        enter(controller, on: TerminalGridPoint(row: 2, column: 0))
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("NEEDLE")
        controller.search.enterScrollMode()
        controller.search.report(selected: 0, start: TerminalGridPoint(row: 1, column: 0), from: surface)
        XCTAssertEqual(
            controller.scrollMode.cursor, TerminalGridPoint(row: 1, column: 0), "precondition: on the newest")

        try type("vey")
        XCTAssertEqual(yanked, "NEEDLE", "precondition: the copy ran")
        try press("n")
        controller.search.report(selected: 1, start: TerminalGridPoint(row: 0, column: 0), from: surface)
        try press("\u{1b}", keyCode: 53)
        XCTAssertNil(controller.focusedPanelForTesting?.findFieldForTesting, "precondition: Esc closed find")

        XCTAssertEqual(try readout(controller), "1:1")
    }

    func test_findOverTheModeTakesTheReadoutsPlace_untilItCloses() throws {
        let (controller, _) = try pane(["hello"] + Array(repeating: "", count: 23))
        enter(controller, on: TerminalGridPoint(row: 0, column: 0))

        controller.handle(.toggleSearch)
        XCTAssertNotNil(controller.focusedPanelForTesting?.findFieldForTesting)
        XCTAssertNil(try readout(controller))
        controller.search.end()

        XCTAssertEqual(try readout(controller), "1:1")
    }
}
