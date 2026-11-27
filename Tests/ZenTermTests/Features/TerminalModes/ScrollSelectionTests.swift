import TerminalKit
import XCTest

@testable import ZenTerm

final class ScrollSelectionTests: XCTestCase {
    private func point(_ row: Int, _ column: Int) -> TerminalGridPoint {
        TerminalGridPoint(row: row, column: column)
    }

    private func row(_ text: String, wraps: Bool = false, continues: Bool = false) -> TerminalGridRow {
        let cells = text.map { TerminalGridCell(text: String($0), width: 1, kind: .output) }
        let padded =
            cells + Array(repeating: TerminalGridCell(text: "", width: 1, kind: .output), count: 10 - cells.count)
        return TerminalGridRow(cells: padded, wraps: wraps, continues: continues, prompt: .none)
    }

    private func span(
        _ kind: ScrollSelection.Kind, _ anchor: TerminalGridPoint, _ cursor: TerminalGridPoint,
        _ rows: [TerminalGridRow]
    ) -> ClosedRange<TerminalGridPoint> {
        ScrollSelection.span(kind, from: anchor, to: cursor, rowCount: rows.count) {
            rows.indices.contains($0) ? rows[$0] : nil
        }
    }

    func test_aSelectionDraggedUpwardsReadsForwards() {
        let rows = Array(repeating: row("abcdefghij"), count: 6)

        XCTAssertEqual(span(.character, point(5, 9), point(2, 4), rows), point(2, 4)...point(5, 9))
    }

    func test_aCharacterSelectionEndingOnAWideCharacterCoversItsSpacer() {
        let wide = TerminalGridRow(
            cells: [
                TerminalGridCell(text: "a", width: 1, kind: .output),
                TerminalGridCell(text: "漢", width: 2, kind: .output),
                TerminalGridCell(text: "", width: 0, kind: .output),
            ], wraps: false, continues: false, prompt: .none)

        XCTAssertEqual(span(.character, point(0, 0), point(0, 1), [wide]), point(0, 0)...point(0, 2))
    }

    func test_aLineSelectionTakesTheWholeWrappedLineEitherWayItWasDragged() {
        let rows = [
            row("before"), row("aaaaaaaaaa", wraps: true), row("bbbbbbbbbb", wraps: true, continues: true),
            row("cc", continues: true), row("after"),
        ]

        XCTAssertEqual(span(.line, point(2, 3), point(2, 3), rows), point(1, 0)...point(3, 9))
        XCTAssertEqual(span(.line, point(3, 0), point(1, 5), rows), point(1, 0)...point(3, 9))
    }

    func test_aLineSelectionOverUnwrappedRowsStopsAtThem() {
        let rows = [row("one"), row("two"), row("three")]

        XCTAssertEqual(span(.line, point(1, 2), point(2, 0), rows), point(1, 0)...point(2, 9))
    }
}
