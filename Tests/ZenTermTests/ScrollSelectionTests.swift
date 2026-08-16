import TerminalKit
import XCTest

@testable import ZenTerm

/// The span a visual selection resolves to. It is what gets painted and what gets yanked, so a
/// wrong ordering copies text the reader never highlighted.
final class ScrollSelectionTests: XCTestCase {
    /// An all-ASCII row, where a column and a cell are the same number. The wide-character mapping
    /// is the controller's, and is covered where it is read from a real grid.
    private let singleWidth: (ScrollCell) -> ClosedRange<Int> = { $0.column...$0.column }

    private func cell(_ row: Int, _ column: Int) -> ScrollCell {
        ScrollCell(row: row, column: column)
    }

    // MARK: charwise

    func test_aForwardSelectionKeepsTheAnchorAtTheStart() {
        let selection = ScrollSelection(kind: .character, anchor: cell(2, 4))
        let range = selection.range(to: cell(5, 9), columns: 80, cells: singleWidth)

        XCTAssertEqual(range.startRow, 2)
        XCTAssertEqual(range.startColumn, 4)
        XCTAssertEqual(range.endRow, 5)
        XCTAssertEqual(range.endColumn, 9)
    }

    func test_aSelectionDraggedUpwardsReadsForwards() {
        // `v` then `k`: the anchor is the LOWER end. Unordered, the backend reads nothing.
        let selection = ScrollSelection(kind: .character, anchor: cell(5, 9))
        let range = selection.range(to: cell(2, 4), columns: 80, cells: singleWidth)

        XCTAssertEqual(range.startRow, 2)
        XCTAssertEqual(range.startColumn, 4)
        XCTAssertEqual(range.endRow, 5)
        XCTAssertEqual(range.endColumn, 9)
    }

    func test_aBackwardsSelectionOnOneRowSwapsOnlyTheColumns() {
        // `v` then `h` `h`: same row, cursor behind the anchor.
        let selection = ScrollSelection(kind: .character, anchor: cell(3, 12))
        let range = selection.range(to: cell(3, 6), columns: 80, cells: singleWidth)

        XCTAssertEqual(range.startRow, 3)
        XCTAssertEqual(range.endRow, 3)
        XCTAssertEqual(range.startColumn, 6)
        XCTAssertEqual(range.endColumn, 12)
    }

    func test_aSelectionOfOneCellIsAOneCellSpan() {
        let selection = ScrollSelection(kind: .character, anchor: cell(7, 3))
        let range = selection.range(to: cell(7, 3), columns: 80, cells: singleWidth)

        XCTAssertEqual(range.rowCount, 1)
        XCTAssertEqual(range.startColumn, 3)
        XCTAssertEqual(range.endColumn, 3)
    }

    // MARK: linewise

    func test_aLineSelectionOpensBothEndsToTheWholeRow() {
        let selection = ScrollSelection(kind: .line, anchor: cell(2, 40))
        let range = selection.range(to: cell(4, 7), columns: 80, cells: singleWidth)

        XCTAssertEqual(range.startColumn, 0)
        XCTAssertEqual(range.endColumn, 79, "the last column of an 80-column grid")
        XCTAssertEqual(range.rowCount, 3)
    }

    func test_aLineSelectionDraggedUpwardsStillStartsAtColumnZero() {
        // A column-aware swap pairs each column with the row it arrived on, so this comes back
        // starting at the last column of row 5.
        let selection = ScrollSelection(kind: .line, anchor: cell(10, 3))
        let range = selection.range(to: cell(5, 60), columns: 80, cells: singleWidth)

        XCTAssertEqual(range.startRow, 5)
        XCTAssertEqual(range.startColumn, 0)
        XCTAssertEqual(range.endRow, 10)
        XCTAssertEqual(range.endColumn, 79)
    }

    func test_aGridWithNoColumnsDoesNotProduceANegativeColumn() {
        // An unsized surface reports zero columns, and -1 reaches the backend as a huge unsigned.
        let selection = ScrollSelection(kind: .line, anchor: cell(0, 0))
        let range = selection.range(to: cell(1, 0), columns: 0, cells: singleWidth)

        XCTAssertEqual(range.endColumn, 0)
    }
}
