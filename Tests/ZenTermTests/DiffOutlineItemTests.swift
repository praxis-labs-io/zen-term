import XCTest

@testable import ZenTerm

final class DiffOutlineItemTests: XCTestCase {
    private func added(_ text: String, new: Int) -> DiffLine {
        DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: new, text: text)
    }
    private func removed(_ text: String, old: Int) -> DiffLine {
        DiffLine(kind: .removed, oldLineNumber: old, newLineNumber: nil, text: text)
    }

    private func file(_ path: String, added addedLines: Int, removed removedLines: Int) -> FileDiff {
        let lines =
            (1...max(1, addedLines)).prefix(addedLines).map { added("a\($0)", new: $0) }
            + (1...max(1, removedLines)).prefix(removedLines).map { removed("r\($0)", old: $0) }
        return FileDiff(
            path: path, oldPath: nil, changeKind: .modified,
            hunks: [Hunk(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: Array(lines))])
    }

    // A section header's badge sums every file beneath it, across nested directories — not just its
    // direct children — so a folded tree still reports the whole slice's magnitude.
    func test_sectionCounts_sumAcrossNestedDirectories() {
        let status = GitDiffRunner.StatusLoad(
            unstaged: [
                file("src/app/main.swift", added: 10, removed: 2),
                file("src/util/helpers.swift", added: 5, removed: 3),
                file("README.md", added: 1, removed: 0),
            ],
            staged: [],
            committed: [], baseBranch: nil, baseSHA: nil)

        let sections = DiffOutlineItem.sections(from: status)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].addedCount, 16)
        XCTAssertEqual(sections[0].removedCount, 5)
    }

    func test_fileNode_reportsItsOwnCounts() {
        let status = GitDiffRunner.StatusLoad(
            unstaged: [file("a.swift", added: 4, removed: 7)], staged: [], committed: [], baseBranch: nil, baseSHA: nil)

        let leaf = DiffOutlineItem.sections(from: status)[0].firstLeafForTesting
        XCTAssertEqual(leaf?.addedCount, 4)
        XCTAssertEqual(leaf?.removedCount, 7)
    }
}

extension DiffOutlineItem {
    /// The first file node in tree order, for tests that need a leaf's own counts.
    var firstLeafForTesting: DiffOutlineItem? {
        if fileDiff != nil { return self }
        for child in children {
            if let leaf = child.firstLeafForTesting { return leaf }
        }
        return nil
    }
}
