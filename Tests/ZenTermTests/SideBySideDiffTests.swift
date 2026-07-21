import XCTest

@testable import ZenTerm

final class SideBySideDiffTests: XCTestCase {
    // Builds a one-hunk FileDiff without going through the parser, so the transform is
    // exercised in isolation from `DiffParser`.
    private func fileDiff(
        path: String = "F.swift", changeKind: ChangeKind = .modified, header: String = "@@ -1,1 +1,1 @@",
        oldStart: Int = 1, newStart: Int = 1, lines: [DiffLine]
    ) -> FileDiff {
        FileDiff(
            path: path, oldPath: nil, changeKind: changeKind,
            hunks: [Hunk(header: header, oldStart: oldStart, newStart: newStart, lines: lines)])
    }

    private func context(_ text: String, old: Int, new: Int) -> DiffLine {
        DiffLine(kind: .context, oldLineNumber: old, newLineNumber: new, text: text)
    }
    private func removed(_ text: String, old: Int) -> DiffLine {
        DiffLine(kind: .removed, oldLineNumber: old, newLineNumber: nil, text: text)
    }
    private func added(_ text: String, new: Int) -> DiffLine {
        DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: new, text: text)
    }

    func test_rows_modifiedHunk_pairsRemovedWithAddedAndKeepsContextOnBothSides() {
        let file = fileDiff(
            header: "@@ -1,3 +1,3 @@",
            lines: [
                context("import Foundation", old: 1, new: 1),
                removed("let x = 1", old: 2),
                added("let x = 2", new: 2),
                context("let y = 3", old: 3, new: 3),
            ])

        let rows = SideBySideDiff.rows(for: file)

        XCTAssertEqual(
            rows,
            [
                .hunkHeader("@@ -1,3 +1,3 @@"),
                .lines(
                    left: DiffCell(lineNumber: 1, text: "import Foundation", kind: .context),
                    right: DiffCell(lineNumber: 1, text: "import Foundation", kind: .context)),
                .lines(
                    left: DiffCell(lineNumber: 2, text: "let x = 1", kind: .removed),
                    right: DiffCell(lineNumber: 2, text: "let x = 2", kind: .added)),
                .lines(
                    left: DiffCell(lineNumber: 3, text: "let y = 3", kind: .context),
                    right: DiffCell(lineNumber: 3, text: "let y = 3", kind: .context)),
            ])
    }

    func test_rows_addedLines_fillLeftSideWithNil() {
        let file = fileDiff(
            changeKind: .added, header: "@@ -0,0 +1,2 @@", oldStart: 0,
            lines: [
                added("line one", new: 1),
                added("line two", new: 2),
            ])

        let rows = SideBySideDiff.rows(for: file)

        XCTAssertEqual(
            rows,
            [
                .hunkHeader("@@ -0,0 +1,2 @@"),
                .lines(left: nil, right: DiffCell(lineNumber: 1, text: "line one", kind: .added)),
                .lines(left: nil, right: DiffCell(lineNumber: 2, text: "line two", kind: .added)),
            ])
    }

    func test_rows_removedLines_fillRightSideWithNil() {
        let file = fileDiff(
            changeKind: .deleted, header: "@@ -1,2 +0,0 @@", newStart: 0,
            lines: [
                removed("line one", old: 1),
                removed("line two", old: 2),
            ])

        let rows = SideBySideDiff.rows(for: file)

        XCTAssertEqual(
            rows,
            [
                .hunkHeader("@@ -1,2 +0,0 @@"),
                .lines(left: DiffCell(lineNumber: 1, text: "line one", kind: .removed), right: nil),
                .lines(left: DiffCell(lineNumber: 2, text: "line two", kind: .removed), right: nil),
            ])
    }

    func test_rows_moreRemovedThanAdded_padsTrailingRemovedWithRightFiller() {
        let file = fileDiff(
            header: "@@ -1,2 +1,1 @@",
            lines: [
                removed("old a", old: 1),
                removed("old b", old: 2),
                added("new a", new: 1),
            ])

        let rows = SideBySideDiff.rows(for: file)

        XCTAssertEqual(
            rows,
            [
                .hunkHeader("@@ -1,2 +1,1 @@"),
                .lines(
                    left: DiffCell(lineNumber: 1, text: "old a", kind: .removed),
                    right: DiffCell(lineNumber: 1, text: "new a", kind: .added)),
                .lines(left: DiffCell(lineNumber: 2, text: "old b", kind: .removed), right: nil),
            ])
    }

    func test_rows_moreAddedThanRemoved_padsTrailingAddedWithLeftFiller() {
        let file = fileDiff(
            header: "@@ -1,1 +1,2 @@",
            lines: [
                removed("old a", old: 1),
                added("new a", new: 1),
                added("new b", new: 2),
            ])

        let rows = SideBySideDiff.rows(for: file)

        XCTAssertEqual(
            rows,
            [
                .hunkHeader("@@ -1,1 +1,2 @@"),
                .lines(
                    left: DiffCell(lineNumber: 1, text: "old a", kind: .removed),
                    right: DiffCell(lineNumber: 1, text: "new a", kind: .added)),
                .lines(left: nil, right: DiffCell(lineNumber: 2, text: "new b", kind: .added)),
            ])
    }

    func test_rows_changeBlockBeforeContext_flushesBeforeEmittingContext() {
        let file = fileDiff(
            header: "@@ -1,2 +1,2 @@",
            lines: [
                removed("old a", old: 1),
                added("new a", new: 1),
                context("shared", old: 2, new: 2),
            ])

        let rows = SideBySideDiff.rows(for: file)

        XCTAssertEqual(
            rows,
            [
                .hunkHeader("@@ -1,2 +1,2 @@"),
                .lines(
                    left: DiffCell(lineNumber: 1, text: "old a", kind: .removed),
                    right: DiffCell(lineNumber: 1, text: "new a", kind: .added)),
                .lines(
                    left: DiffCell(lineNumber: 2, text: "shared", kind: .context),
                    right: DiffCell(lineNumber: 2, text: "shared", kind: .context)),
            ])
    }

    func test_rows_multipleHunks_emitsAHeaderPerHunk() {
        let file = FileDiff(
            path: "F.swift", oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,1 +1,1 @@", oldStart: 1, newStart: 1,
                    lines: [
                        removed("a", old: 1), added("A", new: 1),
                    ]),
                Hunk(
                    header: "@@ -9,1 +9,1 @@", oldStart: 9, newStart: 9,
                    lines: [
                        removed("b", old: 9), added("B", new: 9),
                    ]),
            ])

        let rows = SideBySideDiff.rows(for: file)

        let headers = rows.compactMap { row -> String? in
            if case .hunkHeader(let text) = row { return text }
            return nil
        }
        XCTAssertEqual(headers, ["@@ -1,1 +1,1 @@", "@@ -9,1 +9,1 @@"])
    }

    func test_rows_noHunks_returnsEmpty() {
        let file = FileDiff(path: "Logo.png", oldPath: nil, changeKind: .binary, hunks: [])
        XCTAssertTrue(SideBySideDiff.rows(for: file).isEmpty)
    }
}
