import XCTest

@testable import ZenTerm

/// The linewise-selection model (ZEN-227). Every case here is one an eye can't check: a reference
/// that names the wrong side, or is off by one at a range's end, looks perfectly plausible on screen
/// and sends an agent to the wrong lines.
final class DiffSelectionTests: XCTestCase {
    // A small file rendered both ways, from the same parsed diff, so the two layouts are compared
    // against each other rather than against two hand-written row lists.
    private let file = FileDiff(
        path: "Sources/App/Foo.swift", oldPath: nil, changeKind: .modified,
        hunks: [
            Hunk(
                header: "@@ -10,4 +10,4 @@", oldStart: 10, newStart: 10,
                lines: [
                    DiffLine(kind: .context, oldLineNumber: 10, newLineNumber: 10, text: "func render() {"),
                    DiffLine(kind: .removed, oldLineNumber: 11, newLineNumber: nil, text: "  old()"),
                    DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 11, text: "  new()"),
                    DiffLine(kind: .context, oldLineNumber: 12, newLineNumber: 12, text: "}"),
                ])
        ])

    func test_inline_selectionSpansTheNewSideLineNumbers() {
        let rows = UnifiedDiff.rows(for: file)
        // rows: 0 header, 1 context 10, 2 removed 11(old), 3 added 11(new), 4 context 12
        let selection = DiffSelection.make(rows: rows, selected: IndexSet(1...4))
        XCTAssertEqual(selection.newRange, 10...12)
        XCTAssertEqual(selection.oldRange, 10...12)
        XCTAssertEqual(
            selection.lines, ["func render() {", "  old()", "  new()", "}"],
            "inline rows are one line each, so a removed line contributes its own text")
    }

    func test_sideBySide_pairedRowYieldsTheNewSideText() {
        let rows = SideBySideDiff.rows(for: file)
        // rows: 0 header, 1 context, 2 split(removed 11 | added 11), 3 context
        let selection = DiffSelection.make(rows: rows, selected: IndexSet(integer: 2))
        XCTAssertEqual(selection.lines, ["  new()"], "a paired row shows both sides; the yank takes the new one")
        XCTAssertEqual(selection.newRange, 11...11)
        XCTAssertEqual(selection.oldRange, 11...11, "the old number is still carried for the removed half")
    }

    func test_hunkHeadersContributeNothing() {
        let rows = UnifiedDiff.rows(for: file)
        let headerOnly = DiffSelection.make(rows: rows, selected: IndexSet(integer: 0))
        XCTAssertTrue(headerOnly.isEmpty)
        XCTAssertNil(headerOnly.newRange)

        // A selection that sweeps the header along with real lines keeps only the lines.
        let sweep = DiffSelection.make(rows: rows, selected: IndexSet(0...1))
        XCTAssertEqual(sweep.lines, ["func render() {"])
    }

    func test_removalsOnly_haveNoNewRange_andAnchorOnTheLineAbove() {
        let deletion = FileDiff(
            path: "a.swift", oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,3 +1,1 @@", oldStart: 1, newStart: 1,
                    lines: [
                        DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
                        DiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "gone one"),
                        DiffLine(kind: .removed, oldLineNumber: 3, newLineNumber: nil, text: "gone two"),
                    ])
            ])
        let rows = UnifiedDiff.rows(for: deletion)
        let selection = DiffSelection.make(rows: rows, selected: IndexSet(2...3))  // the two removals
        XCTAssertNil(selection.newRange, "deleted lines aren't in the file on disk")
        XCTAssertEqual(selection.oldRange, 2...3)
        XCTAssertEqual(selection.anchorNewLine, 1, "they follow new-side line 1")
        XCTAssertEqual(selection.lines, ["gone one", "gone two"])
    }

    func test_removalAtTheTopOfAFile_hasNoAnchor() {
        let deletion = FileDiff(
            path: "a.swift", oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,2 +0,1 @@", oldStart: 1, newStart: 1,
                    lines: [DiffLine(kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: "gone")])
            ])
        let rows = UnifiedDiff.rows(for: deletion)
        let selection = DiffSelection.make(rows: rows, selected: IndexSet(integer: 1))
        XCTAssertNil(selection.anchorNewLine, "nothing above it carries a new-side number")
    }

    func test_anchorLooksAboveTheSelection_notOnlyInsideIt() {
        // The anchor has to scan rows *outside* the selection — reading only selected rows would
        // always find nothing (that's the case that produced the nil range in the first place).
        let rows = UnifiedDiff.rows(for: file)
        let selection = DiffSelection.make(rows: rows, selected: IndexSet(integer: 2))  // the lone removal
        XCTAssertNil(selection.newRange)
        XCTAssertEqual(selection.anchorNewLine, 10, "the context line above it")
    }

    func test_outOfBoundsIndicesAreIgnored() {
        let rows = UnifiedDiff.rows(for: file)
        var selected = IndexSet(integer: 1)
        selected.insert(99)  // a stale selection after the file switched
        XCTAssertEqual(DiffSelection.make(rows: rows, selected: selected).lines, ["func render() {"])
    }

    func test_codeTextJoinsWithNewlines() {
        let rows = UnifiedDiff.rows(for: file)
        XCTAssertEqual(
            DiffSelection.make(rows: rows, selected: IndexSet(1...2)).codeText, "func render() {\n  old()")
    }

    func test_emptySelectionIsEmpty() {
        let selection = DiffSelection.make(rows: UnifiedDiff.rows(for: file), selected: IndexSet())
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.codeText, "")
        XCTAssertNil(selection.anchorNewLine, "no selection means nothing to anchor above")
    }
}
