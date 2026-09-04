import XCTest

@testable import ZenTerm

/// The `git status --porcelain=v2 --branch` parse behind the picker's counts. Pure logic over
/// fixture output: the row shows whatever this returns, so a miscount is invisible on screen —
/// "3" and "4" look equally plausible beside a branch name.
final class GitChurnTests: XCTestCase {
    func test_parse_readsAheadAndBehind() {
        let churn = GitChurn.parse(
            """
            # branch.oid abc123
            # branch.head feature/zen-450
            # branch.upstream origin/feature/zen-450
            # branch.ab +2 -5
            """)

        XCTAssertEqual(churn.ahead, 2)
        XCTAssertEqual(churn.behind, 5)
    }

    /// A branch with no upstream has no `# branch.ab` line at all, and must read as "in sync"
    /// rather than as a parse that silently kept the previous row's numbers.
    func test_parse_noUpstreamIsZeroDrift() {
        let churn = GitChurn.parse("# branch.head main")

        XCTAssertEqual(churn.ahead, 0)
        XCTAssertEqual(churn.behind, 0)
    }

    /// `XY` is two independent answers: the index against HEAD, and the working tree against the
    /// index. A file edited and then staged is one entry that counts on both sides, which is the
    /// whole reason staged and modified are separate numbers.
    func test_parse_countsStagedAndModifiedSeparately() {
        let churn = GitChurn.parse(
            """
            1 M. N... 100644 100644 100644 aaa bbb staged-only.swift
            1 .M N... 100644 100644 100644 aaa bbb worktree-only.swift
            1 MM N... 100644 100644 100644 aaa bbb both.swift
            """)

        XCTAssertEqual(churn.staged, 2, "the staged-only file and the one staged then edited again")
        XCTAssertEqual(churn.modified, 2, "the worktree-only file and that same both.swift")
    }

    func test_parse_countsUntrackedRenamedDeletedAndConflicted() {
        let churn = GitChurn.parse(
            """
            ? new-file.swift
            ? another-new.swift
            2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\tolds.swift
            1 D. N... 100644 100644 000000 aaa bbb gone.swift
            u UU N... 100644 100644 100644 100644 aaa bbb ccc clash.swift
            """)

        XCTAssertEqual(churn.untracked, 2)
        XCTAssertEqual(churn.renamed, 1)
        XCTAssertEqual(churn.deleted, 1)
        XCTAssertEqual(churn.conflicted, 1)
    }

    /// A deletion is reported as an ordinary `1` entry with `D` in one half. Counting it as
    /// "staged" or "modified" as well would double it, and a row would claim more work than exists.
    func test_parse_aDeletionCountsOnlyOnce() {
        let churn = GitChurn.parse("1 D. N... 100644 100644 000000 aaa bbb gone.swift")

        XCTAssertEqual(churn.deleted, 1)
        XCTAssertEqual(churn.staged, 0)
        XCTAssertEqual(churn.modified, 0)
    }

    func test_parse_cleanTreeIsEmpty() {
        XCTAssertTrue(GitChurn.parse("# branch.head main\n# branch.ab +0 -0").isEmpty)
        XCTAssertFalse(GitChurn.parse("? untracked.swift").isEmpty)
    }

    /// Real output, from a real repo, so the fixtures above can't drift from the format git
    /// actually writes.
    func test_parse_matchesRealGitOutput() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-churn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func git(_ args: [String]) throws {
            if case .failure(let error) = GitCommand.run(args, in: repo) { throw error }
        }
        try git(["init", "-q"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        try Data("one\n".utf8).write(to: repo.appendingPathComponent("committed.txt"))
        try git(["add", "."])
        try git(["commit", "-qm", "first"])

        try Data("two\n".utf8).write(to: repo.appendingPathComponent("committed.txt"))
        try Data("new\n".utf8).write(to: repo.appendingPathComponent("staged.txt"))
        try git(["add", "staged.txt"])
        try Data("loose\n".utf8).write(to: repo.appendingPathComponent("untracked.txt"))

        let output = try XCTUnwrap(
            try? GitCommand.run(["status", "--porcelain=v2", "--branch"], in: repo).get())
        let churn = GitChurn.parse(output)

        XCTAssertEqual(churn.staged, 1, "staged.txt")
        XCTAssertEqual(churn.modified, 1, "committed.txt")
        XCTAssertEqual(churn.untracked, 1, "untracked.txt")
        XCTAssertEqual(churn.deleted, 0)
        XCTAssertEqual(churn.conflicted, 0)
    }
}
