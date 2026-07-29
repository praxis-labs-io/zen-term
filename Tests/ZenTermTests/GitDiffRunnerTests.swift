import XCTest

@testable import ZenTerm

final class GitDiffRunnerTests: XCTestCase {
    // MARK: scope -> git arguments

    func test_diffArguments_unstaged_diffsWorkingTreeVsIndex() {
        XCTAssertEqual(
            GitDiffRunner.diffArguments(scope: .unstaged, mergeBase: "ignored"),
            ["diff", "--no-color", "--no-ext-diff", "--find-renames"])
    }

    func test_diffArguments_staged_diffsIndexVsHead() {
        XCTAssertEqual(
            GitDiffRunner.diffArguments(scope: .staged, mergeBase: "ignored"),
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "--cached"])
    }

    func test_diffArguments_committed_diffsMergeBaseToHead() {
        XCTAssertEqual(
            GitDiffRunner.diffArguments(scope: .committed, mergeBase: "abc1234"),
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "abc1234", "HEAD"])
    }

    // MARK: base branch name

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

    // MARK: base picker branch order

    func test_orderedBranches_pinsDefaultFirstThenRecency() {
        let ordered = GitDiffRunner.orderedBranches(
            recency: ["feature-x", "main", "bugfix"], default: "main")
        // main hoisted out of its recency slot; everything else keeps git's recency order.
        XCTAssertEqual(ordered, ["main", "feature-x", "bugfix"])
    }

    func test_orderedBranches_defaultNotAmongLocalsIsStillPinned() {
        let ordered = GitDiffRunner.orderedBranches(recency: ["feature-x", "bugfix"], default: "main")
        XCTAssertEqual(ordered, ["main", "feature-x", "bugfix"])  // remote default with no local branch
    }

    /// This layer excludes nothing now. Which branch to keep out of the base list depends on the
    /// *selected* head, which only `DiffViewerOverlay` knows, so the exclusion moved there (ZEN-313).
    /// `DiffViewerOverlayTests` covers it on both sides.
    func test_orderedBranches_excludesNothing_theOverlayDecidesThat() {
        let ordered = GitDiffRunner.orderedBranches(
            recency: ["feature-x", "main", "bugfix"], default: "main")
        XCTAssertEqual(ordered, ["main", "feature-x", "bugfix"])
    }

    func test_orderedBranches_noDefaultKeepsRecencyOrder() {
        let ordered = GitDiffRunner.orderedBranches(recency: ["feature-x", "bugfix"], default: nil)
        XCTAssertEqual(ordered, ["feature-x", "bugfix"])
    }

    func test_orderedBranches_deduplicates() {
        let ordered = GitDiffRunner.orderedBranches(
            recency: ["main", "feature-x", "feature-x"], default: "main")
        XCTAssertEqual(ordered, ["main", "feature-x"])  // the repeat collapses, nothing is excluded
    }

    // MARK: untracked fold (always unstaged)

    func test_syntheticUntrackedDiffs_addsAsAddedFiles() {
        let result = GitDiffRunner.syntheticUntrackedDiffs(
            untrackedFiles: [(path: "New.swift", contents: "a\nb\n")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "New.swift")
        XCTAssertEqual(result[0].changeKind, .added)
        XCTAssertEqual(result[0].addedCount, 2)
        XCTAssertEqual(result[0].removedCount, 0)
    }

    func test_syntheticUntrackedDiffs_emptyFile_hasNoAddedLines() {
        let result = GitDiffRunner.syntheticUntrackedDiffs(
            untrackedFiles: [(path: "Empty.txt", contents: "")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].addedCount, 0)
        XCTAssertTrue(result[0].hunks.isEmpty)
    }

    // MARK: head selection (ZEN-313)

    /// The committed slice compares the fork point to whichever head the reader picked. Default is
    /// `HEAD`, so the ordinary case is byte-identical to before.
    func test_diffArguments_committed_defaultsToHead() {
        XCTAssertEqual(
            GitDiffRunner.diffArguments(scope: .committed, mergeBase: "abc123"),
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "abc123", "HEAD"])
    }

    func test_diffArguments_committed_honoursAPickedBranch() {
        XCTAssertEqual(
            GitDiffRunner.diffArguments(scope: .committed, mergeBase: "abc123", head: "feature/x"),
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "abc123", "feature/x"])
    }

    /// Real `git worktree list --porcelain`: `\n\n`-separated records, and a trailing blank record
    /// because the output ends with one. Verified against live output before this was written.
    func test_worktrees_parsesPorcelainRecords() {
        let porcelain = """
            worktree /Users/dev/project
            HEAD 5937c9650aaa4b87e2dbec0fbe0dd60b5260b8b9
            branch refs/heads/main

            worktree /Users/dev/project/.worktrees/feature
            HEAD fdf416344c239fd75f00d272d0ae54b7bb9b0a3e
            branch refs/heads/feature/nested-name


            """
        XCTAssertEqual(
            GitDiffRunner.worktrees(fromPorcelain: porcelain),
            [
                "main": URL(fileURLWithPath: "/Users/dev/project"),
                "feature/nested-name": URL(fileURLWithPath: "/Users/dev/project/.worktrees/feature"),
            ],
            "a branch name with slashes survives, and the trailing blank record yields nothing")
    }

    /// A detached worktree has no branch to offer, so it contributes no entry rather than a blank key.
    func test_worktrees_skipsDetachedRecords() {
        let porcelain = """
            worktree /Users/dev/project
            HEAD aaa
            branch refs/heads/main

            worktree /Users/dev/project/.worktrees/loose
            HEAD bbb
            detached

            """
        XCTAssertEqual(
            GitDiffRunner.worktrees(fromPorcelain: porcelain),
            ["main": URL(fileURLWithPath: "/Users/dev/project")])
    }

    func test_worktrees_emptyOutput_yieldsNothing() {
        XCTAssertTrue(GitDiffRunner.worktrees(fromPorcelain: "").isEmpty)
    }

    /// The head picker leads with the checked-out branch, unlike the base picker which excludes it.
    /// That difference is the whole reason these are two functions.
    func test_orderedHeads_leadsWithTheCheckedOutBranch() {
        let heads = GitDiffRunner.orderedHeads(
            recency: ["feature", "main", "old"], current: "main", worktrees: [:])

        XCTAssertEqual(heads.map(\.name), ["main", "feature", "old"])
        XCTAssertEqual(heads.map(\.isCurrent), [true, false, false])
    }

    /// Both orderings now offer every branch. Which one each picker hides depends on what the *other*
    /// picker has selected, and neither is knowable here, so the exclusion is the overlay's on both
    /// sides. What stays different at this layer is only the ordering: default-first vs current-first.
    func test_orderedBranchesAndHeads_bothOfferEveryBranch_differingOnlyInOrder() {
        let recency = ["feature", "main"]
        XCTAssertEqual(
            GitDiffRunner.orderedBranches(recency: recency, default: "main"), ["main", "feature"])
        XCTAssertEqual(
            GitDiffRunner.orderedHeads(recency: recency, current: "feature", worktrees: [:])
                .map(\.name), ["feature", "main"])
    }

    /// Which branches have a worktree decides what the viewer can show, so the tagging has to survive
    /// the ordering.
    func test_orderedHeads_tagsBranchesThatHaveAWorktree() {
        let path = URL(fileURLWithPath: "/Users/dev/project/.worktrees/feature")
        let heads = GitDiffRunner.orderedHeads(
            recency: ["feature", "loose"], current: "main", worktrees: ["feature": path])

        XCTAssertEqual(heads.first { $0.name == "feature" }?.worktree, path)
        XCTAssertTrue(heads.first { $0.name == "feature" }?.hasWorktree == true)
        XCTAssertNil(heads.first { $0.name == "loose" }?.worktree)
        XCTAssertFalse(heads.first { $0.name == "loose" }?.hasWorktree == true)
    }

    func test_orderedHeads_deduplicatesAndDropsBlanks() {
        let heads = GitDiffRunner.orderedHeads(
            recency: ["main", "", "feature", "feature"], current: "main", worktrees: [:])
        XCTAssertEqual(heads.map(\.name), ["main", "feature"])
    }

    /// A detached checkout has no current branch, so nothing is pinned first.
    func test_orderedHeads_detachedCheckout_hasNoCurrent() {
        let heads = GitDiffRunner.orderedHeads(
            recency: ["feature", "main"], current: nil, worktrees: [:])
        XCTAssertEqual(heads.map(\.name), ["feature", "main"])
        XCTAssertFalse(heads.contains { $0.isCurrent })
    }

    /// The committed slice's new-side blob has to come from the picked branch, or the highlighter
    /// paints the diff of one branch with the file contents of another.
    func test_blobSource_committedNewSide_followsThePickedHead() {
        var file = FileDiff(path: "Sources/App.swift", oldPath: nil, changeKind: .modified, hunks: [])
        file.scope = .committed
        file.baseSHA = "abc123"
        file.headRef = "feature/x"

        XCTAssertEqual(
            GitDiffRunner.blobSource(for: file, side: .new),
            .git(["show", "feature/x:Sources/App.swift"]))
    }

    func test_blobSource_committedNewSide_defaultsToHeadWhenNoBranchPicked() {
        var file = FileDiff(path: "Sources/App.swift", oldPath: nil, changeKind: .modified, hunks: [])
        file.scope = .committed
        file.baseSHA = "abc123"

        XCTAssertEqual(
            GitDiffRunner.blobSource(for: file, side: .new),
            .git(["show", "HEAD:Sources/App.swift"]))
    }
}
