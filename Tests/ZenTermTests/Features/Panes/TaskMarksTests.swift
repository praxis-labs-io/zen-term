import TerminalKit
import XCTest

@testable import ZenTerm

final class TaskMarksTests: XCTestCase {
    func test_aReadWhileAResizeHasNotReachedTheGridReadsTheTask() {
        let pane = RecordingSurface()
        pane.start(TerminalSurfaceConfig())
        pane.rows = ["$ earlier", "$ make"]
        let marks = TaskMarks()
        let id = SurfaceID(raw: 1)
        marks.mark(id, at: pane)
        pane.rows = ["$ earlier", "$ make", "built"]
        pane.recordingGrid.widthBeforeResize = 40

        XCTAssertEqual(marks.read(since: id, in: pane), .text("$ make\nbuilt", truncated: false))
    }
}
