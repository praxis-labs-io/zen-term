import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

final class OutputWatchTests: XCTestCase {
    private func surface(_ rows: [String]) -> RecordingSurface {
        let surface = RecordingSurface()
        surface.start(TerminalSurfaceConfig())
        surface.rows = rows
        return surface
    }

    func test_textAlreadyOnScreenWhenTheWaitBeganIsNotAMatch() {
        let pane = surface(["server ready", "$ "])
        let watch = OutputWatch(needle: "ready", surface: pane)
        XCTAssertFalse(watch.sawNeedle(in: pane))
        pane.rows = ["server ready", "$ ls"]
        XCTAssertFalse(watch.sawNeedle(in: pane))
    }

    func test_textPrintedAfterTheWaitBeganIsAMatch() {
        let pane = surface(["$ npm run dev"])
        let watch = OutputWatch(needle: "ready", surface: pane)
        pane.rows = ["$ npm run dev", "compiling"]
        XCTAssertFalse(watch.sawNeedle(in: pane))
        pane.rows = ["$ npm run dev", "compiling", "server ready"]
        XCTAssertTrue(watch.sawNeedle(in: pane))
    }

    func test_textAPaneStartingAfterTheWaitBeganPrintsIsAMatch() {
        let pane = RecordingSurface()
        let watch = OutputWatch(needle: "ready", surface: pane)
        XCTAssertFalse(watch.sawNeedle(in: pane))
        pane.start(TerminalSurfaceConfig())
        pane.rows = ["server ready", "$ "]
        XCTAssertTrue(watch.sawNeedle(in: pane))
    }

    func test_textPrintedAfterAWaitThatBeganMidResizeIsAMatch() {
        let pane = surface(["$ npm run dev"])
        pane.recordingGrid.widthBeforeResize = 40
        let watch = OutputWatch(needle: "ready", surface: pane)
        pane.recordingGrid.widthBeforeResize = nil
        pane.rows = ["$ npm run dev", "server ready"]
        XCTAssertTrue(watch.sawNeedle(in: pane))
    }

    func test_textAtTheScreensTopWhileAResizeHasNotReachedTheGridIsAMatch() {
        let pane = surface(["$ npm run dev", "", "", ""])
        pane.scrollback = ["earlier"]
        pane.cellMetrics = TerminalCellMetrics(columns: 80, rows: 2, cellWidth: 8, cellHeight: 16, gridInset: 2)
        let watch = OutputWatch(needle: "ready", surface: pane)
        pane.rows = ["$ npm run dev", "server ready", "", ""]
        XCTAssertTrue(watch.sawNeedle(in: pane))
    }

    func test_theCursorLineGrowingIntoTheNeedleIsAMatch() {
        let pane = surface(["building... "])
        let watch = OutputWatch(needle: "done", surface: pane)
        pane.rows = ["building... done"]
        XCTAssertTrue(watch.sawNeedle(in: pane))
    }

    func test_aRedrawnScreenOnlyMatchesWhenTheNeedleShowsUpMoreOften() {
        let pane = surface(["a", "b ready", "c"])
        let watch = OutputWatch(needle: "ready", surface: pane)
        pane.rows = ["x", "b ready", "y"]
        XCTAssertFalse(watch.sawNeedle(in: pane))
        pane.rows = ["x", "b ready", "ready"]
        XCTAssertTrue(watch.sawNeedle(in: pane))
    }

    func test_anAnsweredWaitFreesItsMark() throws {
        let pane = surface(["$ npm run dev"])
        let listing = ListResult.Pane(
            token: 1, drawer: nil, title: "", cwd: nil, busy: false, agent: nil, name: nil, parent: nil,
            firstTask: nil)
        var answered = false
        let wait = try XCTUnwrap(
            PaneWait(
                PaneWait.Watched(
                    token: 1, surfaceID: SurfaceID(raw: 1), surface: pane, readsForeground: false, closesOnExit: false,
                    pane: { listing },
                    exit: { nil }, awaitsQueuedTask: { false }),
                caller: nil, output: "ready"
            ) { _ in answered = true })
        wait.start(timeout: nil)
        XCTAssertEqual(pane.recordingGrid.liveMarks, 1, "the wait holds a mark while it watches")

        pane.rows = ["$ npm run dev", "server ready"]
        waitUntil(answered, "the wait to answer")

        XCTAssertEqual(pane.recordingGrid.liveMarks, 0)
        XCTAssertFalse(wait.isWatching)
    }
}
