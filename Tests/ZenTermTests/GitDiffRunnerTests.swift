import XCTest

@testable import ZenTerm

final class GitDiffRunnerTests: XCTestCase {
    // MARK: scope -> git arguments

    func test_diffArguments_branch_diffsAgainstMergeBase() {
        XCTAssertEqual(
            GitDiffRunner.diffArguments(scope: .branch, mergeBase: "abc1234"),
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "abc1234"])
    }

    func test_diffArguments_committed_diffsMergeBaseToHead() {
        XCTAssertEqual(
            GitDiffRunner.diffArguments(scope: .committed, mergeBase: "abc1234"),
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "abc1234", "HEAD"])
    }

    func test_diffArguments_uncommitted_diffsHeadToWorkingTree() {
        XCTAssertEqual(
            GitDiffRunner.diffArguments(scope: .uncommitted, mergeBase: "ignored"),
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "HEAD"])
    }

    // MARK: base branch resolution

    func test_defaultBranchName_stripsOriginPrefix() {
        XCTAssertEqual(GitDiffRunner.defaultBranchName(fromSymbolicRef: "origin/main"), "main")
        XCTAssertEqual(GitDiffRunner.defaultBranchName(fromSymbolicRef: "origin/master"), "master")
    }

    func test_defaultBranchName_keepsSlashesAfterOrigin() {
        XCTAssertEqual(GitDiffRunner.defaultBranchName(fromSymbolicRef: "origin/release/1.x"), "release/1.x")
    }

    func test_defaultBranchName_trimsWhitespace() {
        XCTAssertEqual(GitDiffRunner.defaultBranchName(fromSymbolicRef: "  origin/main\n"), "main")
    }

    func test_defaultBranchName_emptyIsNil() {
        XCTAssertNil(GitDiffRunner.defaultBranchName(fromSymbolicRef: "\n"))
    }

    // MARK: untracked fold (scope-dependent)

    func test_syntheticUntrackedDiffs_committedScope_excludesUntracked() {
        let result = GitDiffRunner.syntheticUntrackedDiffs(
            scope: .committed, untrackedFiles: [(path: "New.swift", contents: "a\nb\n")])
        XCTAssertTrue(result.isEmpty)
    }

    func test_syntheticUntrackedDiffs_branchScope_addsAsAddedFiles() {
        let result = GitDiffRunner.syntheticUntrackedDiffs(
            scope: .branch, untrackedFiles: [(path: "New.swift", contents: "a\nb\n")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "New.swift")
        XCTAssertEqual(result[0].changeKind, .added)
        XCTAssertEqual(result[0].addedCount, 2)
        XCTAssertEqual(result[0].removedCount, 0)
    }

    func test_syntheticUntrackedDiffs_uncommittedScope_addsAsAddedFiles() {
        let result = GitDiffRunner.syntheticUntrackedDiffs(
            scope: .uncommitted, untrackedFiles: [(path: "N.txt", contents: "only line")])
        XCTAssertEqual(result.map(\.changeKind), [.added])
        XCTAssertEqual(result[0].addedCount, 1)
    }

    func test_syntheticUntrackedDiffs_emptyFile_hasNoAddedLines() {
        let result = GitDiffRunner.syntheticUntrackedDiffs(
            scope: .branch, untrackedFiles: [(path: "Empty.txt", contents: "")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].addedCount, 0)
        XCTAssertTrue(result[0].hunks.isEmpty)
    }
}
