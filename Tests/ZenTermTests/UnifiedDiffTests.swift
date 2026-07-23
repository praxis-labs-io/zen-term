import XCTest

@testable import ZenTerm

/// The inline (unified) transform: one row per line in original order, plus a header per hunk. The
/// side-by-side pairing is `SideBySideDiffTests`' subject; this is the other renderer over the same
/// parsed model.
final class UnifiedDiffTests: XCTestCase {
    private func fileDiff(header: String = "@@ -1,1 +1,1 @@", lines: [DiffLine]) -> FileDiff {
        FileDiff(
            path: "F.swift", oldPath: nil, changeKind: .modified,
            hunks: [Hunk(header: header, oldStart: 1, newStart: 1, lines: lines)])
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

    func test_rows_oneRowPerLineInOriginalOrder_eachCarryingItsGutters() {
        let file = fileDiff(
            header: "@@ -1,3 +1,3 @@",
            lines: [
                context("import Foundation", old: 1, new: 1),
                removed("let x = 1", old: 2),
                added("let x = 2", new: 2),
                context("let y = 3", old: 3, new: 3),
            ])

        XCTAssertEqual(
            UnifiedDiff.rows(for: file),
            [
                .hunkHeader("@@ -1,3 +1,3 @@"),
                .unified(text: "import Foundation", kind: .context, old: 1, new: 1),
                .unified(text: "let x = 1", kind: .removed, old: 2, new: nil),
                .unified(text: "let x = 2", kind: .added, old: nil, new: 2),
                .unified(text: "let y = 3", kind: .context, old: 3, new: 3),
            ])
    }

    func test_rows_multipleHunks_emitAHeaderPerHunk() {
        let file = FileDiff(
            path: "F.swift", oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,1 +1,1 @@", oldStart: 1, newStart: 1,
                    lines: [removed("a", old: 1), added("A", new: 1)]),
                Hunk(
                    header: "@@ -9,1 +9,1 @@", oldStart: 9, newStart: 9,
                    lines: [removed("b", old: 9), added("B", new: 9)]),
            ])

        let rows = UnifiedDiff.rows(for: file)
        let headers = rows.compactMap { row -> String? in
            if case .hunkHeader(let text) = row { return text }
            return nil
        }
        XCTAssertEqual(headers, ["@@ -1,1 +1,1 @@", "@@ -9,1 +9,1 @@"])
        XCTAssertEqual(rows.count, 6, "2 headers + 4 lines, no pairing")
    }

    func test_rows_noHunks_returnsEmpty() {
        let file = FileDiff(path: "Logo.png", oldPath: nil, changeKind: .binary, hunks: [])
        XCTAssertTrue(UnifiedDiff.rows(for: file).isEmpty)
    }
}
