import TerminalKit
import XCTest

@testable import ZenTerm

final class ScrollCursorViewTests: XCTestCase {
    func test_aFlashStartingPastANarrowedRowStillLaysOut() {
        let metrics = TerminalCellMetrics(columns: 40, rows: 24, cellWidth: 8, cellHeight: 16, gridInset: 2)
        let range = TerminalViewportRange(startRow: 2, startColumn: 70, endRow: 4, endColumn: 10)

        let rects = ScrollCursorView.rects(for: range, metrics: metrics)

        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(rects.first, metrics.cellFrame(row: 2, columns: 39...39))
    }
}
