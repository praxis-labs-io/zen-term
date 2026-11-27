import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyGridTests: XCTestCase {
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
    }

    override func tearDown() {
        for surface in surfaces {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        surfaces = []
        window.close()
        window = nil
        super.tearDown()
    }

    private func mounted(_ script: String) throws -> (GhosttySurface, TerminalGrid) {
        let surface = GhosttySurface()
        surfaces.append(surface)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", script + "; sleep 100"]))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        return (surface, try XCTUnwrap(surface.grid))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 20, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return done()
    }

    private func text(of row: TerminalGridRow?) -> String? {
        row.map { $0.cells.map { $0.text.isEmpty && $0.width > 0 ? " " : $0.text }.joined() }?
            .trimmingCharacters(in: .whitespaces)
    }

    private func rowIndex(_ grid: TerminalGrid, _ text: String) -> Int? {
        (0..<grid.rowCount).last { self.text(of: grid.row($0)) == text }
    }

    private func awaitRow(_ grid: TerminalGrid, _ text: String) throws -> Int {
        waitFor { self.rowIndex(grid, text) != nil }
        return try XCTUnwrap(rowIndex(grid, text), "\(text) never printed")
    }

    func test_aMarkStaysOnItsTextThroughOutputAndAResize() throws {
        let (surface, grid) = try mounted("printf 'MARKHERE %080d\\n' 0; sleep 1; seq 300")
        let line = "MARKHERE " + String(repeating: "0", count: 80)
        let row = try awaitRow(grid, line)
        let mark = try XCTUnwrap(grid.mark(TerminalGridPoint(row: row, column: 0)))
        _ = try awaitRow(grid, "300")

        guard case .at(let afterOutput) = mark.place else { return XCTFail("\(mark.place)") }
        XCTAssertEqual(text(of: grid.row(afterOutput.row)), line)

        let columns = surface.cellMetrics?.columns
        surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 560)
        waitFor { self.surface(surface, rewrapped: columns) }
        guard case .at(let afterResize) = mark.place else { return XCTFail("\(mark.place)") }
        XCTAssertEqual(text(of: grid.row(afterResize.row))?.hasPrefix("MARKHERE"), true)
        XCTAssertEqual(grid.row(afterResize.row)?.wraps, true, "the line now wraps, so the resize moved text")
    }

    private func surface(_ surface: GhosttySurface, rewrapped columns: Int?) -> Bool {
        guard let grid = surface.grid, surface.cellMetrics?.columns != columns,
            let row = rowIndex(grid, "300")
        else { return false }
        return (0..<row).contains { grid.row($0)?.wraps == true }
    }

    func test_aMarkIsGoneOnceTheScrollbackDropsItsRow() throws {
        let (surface, grid) = try mounted("echo MARKHERE; sleep 1; seq 400000; echo DONE")
        let mark = try XCTUnwrap(grid.mark(TerminalGridPoint(row: try awaitRow(grid, "MARKHERE"), column: 0)))
        XCTAssertTrue(waitFor(60) { surface.activeScreenText?.contains("DONE") == true })

        XCTAssertEqual(mark.place, .gone)
    }

    func test_aMarkIsGoneOnceTheSurfaceIs() throws {
        let (surface, grid) = try mounted("echo MARKHERE")
        let mark = try XCTUnwrap(grid.mark(TerminalGridPoint(row: try awaitRow(grid, "MARKHERE"), column: 0)))

        surface.terminate()

        XCTAssertEqual(mark.place, .gone)
        XCTAssertNil(surface.grid)
    }

    func test_aMarkIsAsideWhileTheAlternateScreenShows() throws {
        let (_, grid) = try mounted("echo MARKHERE; sleep 1; printf '\\033[?1049h'; sleep 1; printf '\\033[?1049l'")
        let row = try awaitRow(grid, "MARKHERE")
        let mark = try XCTUnwrap(grid.mark(TerminalGridPoint(row: row, column: 0)))

        XCTAssertTrue(waitFor { mark.place == .aside })
        XCTAssertTrue(waitFor { mark.place == .at(TerminalGridPoint(row: row, column: 0)) })
    }

    func test_aWideCharacterIsOneCellFollowedByASpacer() throws {
        let (_, grid) = try mounted("printf 'a\\346\\274\\242b\\n'")
        let row = try XCTUnwrap(grid.row(try awaitRow(grid, "a漢b")))

        XCTAssertEqual(row.cells.prefix(4).map(\.text), ["a", "漢", "", "b"])
        XCTAssertEqual(row.cells.prefix(4).map(\.width), [1, 2, 0, 1])
    }

    func test_promptMarksReadAsPromptInputAndOutput() throws {
        let (_, grid) = try mounted(
            #"printf '\033]133;A\007PROMPT> \033]133;B\007echo hi\n\033]133;C\007OUT2\n'"#)
        let output = try XCTUnwrap(grid.row(try awaitRow(grid, "OUT2")))
        let prompt = try XCTUnwrap(grid.row(try awaitRow(grid, "PROMPT> echo hi")))

        XCTAssertEqual(prompt.prompt, .start)
        XCTAssertEqual(prompt.cells[0].kind, .prompt)
        XCTAssertEqual(prompt.cells[8].kind, .input)
        XCTAssertEqual(output.prompt, TerminalGridRow.Prompt.none)
        XCTAssertEqual(output.cells[0].kind, .output)
    }

    func test_textReadsAcrossTheViewportsTopEdge() throws {
        let (_, grid) = try mounted("seq 5000")
        let last = try awaitRow(grid, "5000")
        let top = grid.viewportTop

        let read = grid.text(
            from: TerminalGridPoint(row: top - 2, column: 0), to: TerminalGridPoint(row: top + 1, column: 9))

        let first = try XCTUnwrap(Int(text(of: grid.row(top - 2)) ?? ""))
        XCTAssertEqual(read, (first...first + 3).map(String.init).joined(separator: "\n"))
        XCTAssertEqual(grid.cursorPoint?.row, last + 1)
    }

    func test_aSetSelectionReadsBackCopiesAndClears() throws {
        let (surface, grid) = try mounted("seq 5000")
        let row = try awaitRow(grid, "10")
        let range = TerminalGridPoint(row: row, column: 0)...TerminalGridPoint(row: row + 1, column: 1)

        grid.setSelection(range)
        XCTAssertEqual(grid.selectionBounds, range)
        XCTAssertEqual(surface.copySelection(), "10\n11")

        grid.setSelection(nil)
        XCTAssertNil(grid.selectionBounds)
        XCTAssertNil(surface.copySelection())
    }

    func test_settingAndClearingTheSelectionTellsTheDelegate() throws {
        let (surface, grid) = try mounted("seq 50")
        let recorder = SelectionRecorder()
        surface.delegate = recorder
        let row = try awaitRow(grid, "10")

        grid.setSelection(TerminalGridPoint(row: row, column: 0)...TerminalGridPoint(row: row, column: 1))
        XCTAssertTrue(waitFor(5) { recorder.changes == 1 })
        surface.clearScreen()
        XCTAssertTrue(waitFor(5) { recorder.changes == 2 }, "a screen clear drops the selection")
        XCTAssertNil(grid.selectionBounds)
    }

    func test_aFullResetDroppingTheSelectionTellsTheDelegate() throws {
        let (surface, grid) = try mounted("seq 50; sleep 2; printf '\\033c'; echo AFTER")
        let recorder = SelectionRecorder()
        surface.delegate = recorder
        let row = try awaitRow(grid, "10")

        grid.setSelection(TerminalGridPoint(row: row, column: 0)...TerminalGridPoint(row: row, column: 1))
        XCTAssertTrue(waitFor(5) { recorder.changes == 1 })
        _ = try awaitRow(grid, "AFTER")

        XCTAssertNil(grid.selectionBounds)
        XCTAssertTrue(waitFor(5) { recorder.changes == 2 }, "a reset drops the selection")
    }

    func test_aColumnPastTheRightEdgeIsOutsideTheGrid() throws {
        let (surface, grid) = try mounted("echo HERE")
        let row = try awaitRow(grid, "HERE")
        let settled = waitFor { grid.row(row)?.cells.count == surface.cellMetrics?.columns }
        XCTAssertTrue(settled, "the grid never took the view's width")
        let columns = try XCTUnwrap(grid.row(row)?.cells.count)
        let past = TerminalGridPoint(row: row, column: columns)

        XCTAssertNil(grid.mark(past))
        XCTAssertNil(grid.text(from: TerminalGridPoint(row: row, column: 0), to: past))
        XCTAssertNotNil(grid.mark(TerminalGridPoint(row: row, column: columns - 1)))
    }

    func test_aSurfaceReleasedWithoutTerminatingLeavesItsMarksGone() throws {
        var surface: GhosttySurface? = GhosttySurface()
        surface?.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "echo HERE; sleep 100"]))
        try XCTSkipIf(surface?.surfacePtr == nil, "ghostty_surface_new failed")
        surface?.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(try XCTUnwrap(surface?.view))
        let grid = try XCTUnwrap(surface?.grid)
        let mark = try XCTUnwrap(grid.mark(TerminalGridPoint(row: try awaitRow(grid, "HERE"), column: 0)))
        weak let released = surface

        surface?.view.removeFromSuperview()
        surface = nil

        XCTAssertNil(released, "the test kept the surface alive, so deinit never ran")
        XCTAssertEqual(mark.place, .gone)
    }

    func test_aSurfaceNeverAskedForItsGridReleasesWithoutTerminating() throws {
        var surface: GhosttySurface? = GhosttySurface()
        surface?.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))
        try XCTSkipIf(surface?.surfacePtr == nil, "ghostty_surface_new failed")
        weak let released = surface

        surface = nil

        XCTAssertNil(released)
    }

    func test_theSelectedSearchMatchCarriesItsStart() throws {
        let (surface, grid) = try mounted("seq 50; echo 'xx NEEDLE'")
        let recorder = SelectionRecorder()
        surface.delegate = recorder
        let row = try awaitRow(grid, "xx NEEDLE")

        surface.search("NEEDLE")
        waitFor(5) { recorder.searchTotal == 1 }
        surface.stepSearch(.next)

        XCTAssertTrue(waitFor(5) { recorder.searchStart != nil })
        XCTAssertEqual(recorder.searchStart, TerminalGridPoint(row: row, column: 3))
    }
}

private final class SelectionRecorder: TerminalSurfaceDelegate {
    var changes = 0
    var searchTotal: Int?
    var searchStart: TerminalGridPoint?
    func surfaceSelectionDidChange(_ s: TerminalSurface) { changes += 1 }
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?) { searchTotal = total }
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?, start: TerminalGridPoint?) {
        searchStart = start
    }
}
