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
            committed: [], baseBranch: nil, baseSHA: nil, currentBranch: nil)

        let sections = DiffOutlineItem.sections(from: status)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].addedCount, 16)
        XCTAssertEqual(sections[0].removedCount, 5)
    }

    func test_fileNode_reportsItsOwnCounts() {
        let status = GitDiffRunner.StatusLoad(
            unstaged: [file("a.swift", added: 4, removed: 7)], staged: [], committed: [], baseBranch: nil,
            baseSHA: nil, currentBranch: nil)

        let leaf = DiffOutlineItem.sections(from: status)[0].firstLeafForTesting
        XCTAssertEqual(leaf?.addedCount, 4)
        XCTAssertEqual(leaf?.removedCount, 7)
    }

    // MARK: identity

    private func identities(in items: [DiffOutlineItem]) -> [String] {
        items.flatMap { [$0.identity] + identities(in: $0.children) }
    }

    func test_identity_isStableAcrossARebuildFromTheSameStatus() {
        let status = GitDiffRunner.StatusLoad(
            unstaged: [file("src/app/main.swift", added: 1, removed: 0), file("README.md", added: 1, removed: 0)],
            staged: [], committed: [], baseBranch: nil, baseSHA: nil, currentBranch: nil)

        // Two independent boxings of the same status — the rebuild a reload does — must agree, or the
        // folds and selection have nothing to match against.
        let first = identities(in: DiffOutlineItem.sections(from: status))
        let second = identities(in: DiffOutlineItem.sections(from: status))
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("Unstaged\u{1}src/app/main.swift"))
        // The single-child chain src > app folds into one directory node, so its identity is the
        // folded path.
        XCTAssertTrue(first.contains("Unstaged\u{1}src/app"), "the folded directory carries its path")
    }

    func test_identity_distinguishesTheSamePathInTwoSections() {
        // A file changed in the working tree and since the base appears in both slices — same path, two
        // rows, so two identities (the same reason `highlightKey` carries scope).
        let status = GitDiffRunner.StatusLoad(
            unstaged: [file("a.swift", added: 1, removed: 0)], staged: [],
            committed: [file("a.swift", added: 1, removed: 0)], baseBranch: "main", baseSHA: "abc",
            currentBranch: "feature")

        let all = identities(in: DiffOutlineItem.sections(from: status))
        XCTAssertTrue(all.contains("Unstaged\u{1}a.swift"))
        XCTAssertTrue(all.contains("Committed\u{1}a.swift"))
        XCTAssertEqual(Set(all).count, all.count, "no two rows share an identity")
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
