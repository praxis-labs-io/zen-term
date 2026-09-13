import XCTest

@testable import ZenTerm

final class WorktreeStoreTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WorktreeStore.rootOverrideForTesting = root.appendingPathComponent(
            "worktrees", isDirectory: true)
        repo = try GitFixture.makeRepoWithOrigin(under: root)
    }

    override func tearDownWithError() throws {
        WorktreeStore.rootOverrideForTesting = nil
        WorktreeStore.beforeClaimingForTesting = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func test_createExisting_landsOnABranchCheckedOutNowhere() throws {
        try GitFixture.run(["branch", "parked"], in: repo)

        let worktree = try WorktreeStore.create(existingBranch: "parked", in: repo)

        XCTAssertEqual(worktree.branch, "parked")
        XCTAssertEqual(worktree.head, try GitFixture.run(["rev-parse", "parked"], in: repo))
        XCTAssertEqual(try GitFixture.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), "main")
    }

    func test_createExisting_leavesTheBranchAloneWhenTheAddFails() throws {
        try GitFixture.run(["branch", "parked"], in: repo)
        let before = try GitFixture.run(["rev-parse", "parked"], in: repo)
        try failingPostCheckoutHook()

        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "parked", in: repo))

        XCTAssertEqual(try GitFixture.run(["rev-parse", "parked"], in: repo), before)
        XCTAssertTrue(try GitFixture.branches(in: repo).contains("parked"))
        XCTAssertEqual(try WorktreeStore.list(in: repo), [], "no registration survives")
    }

    func test_createExisting_refusesABranchThatIsNoLongerThere() throws {
        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "ghost", in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .branchNotThere("ghost"))
        }
    }

    func test_createExisting_refusesTheDefaultBranchWhenTheMainCheckoutIsOnIt() throws {
        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "main", in: repo)) { error in
            XCTAssertEqual(
                error as? WorktreeStore.WorktreeError, .mainCheckoutOnDefaultBranch("main"))
        }
    }

    func test_createExisting_refusesABranchAWorktreeAlreadyHas() throws {
        try GitFixture.run(["branch", "parked"], in: repo)
        _ = try WorktreeStore.create(existingBranch: "parked", in: repo)

        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "parked", in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .branchInWorktree("parked"))
        }
    }

    func test_createExisting_refusesWhenTheMainCheckoutIsOnItAndDirty() throws {
        try GitFixture.run(["checkout", "-q", "-b", "busy"], in: repo)
        try GitFixture.write("edited\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.write("new\n", to: repo.appendingPathComponent("scratch.txt"))

        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "busy", in: repo)) { error in
            XCTAssertEqual(
                error as? WorktreeStore.WorktreeError, .branchInMainCheckout("busy", uncommitted: 2))
        }
        XCTAssertEqual(try GitFixture.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), "busy")
        XCTAssertEqual(try WorktreeStore.list(in: repo), [], "nothing written")
    }

    func test_createExisting_countsEveryFileInAnUntrackedDirectory() throws {
        try GitFixture.run(["checkout", "-q", "-b", "busy"], in: repo)
        let dir = repo.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["a.log", "b.log", "c.log"] {
            try GitFixture.write("x\n", to: dir.appendingPathComponent(name))
        }

        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "busy", in: repo)) { error in
            XCTAssertEqual(
                error as? WorktreeStore.WorktreeError, .branchInMainCheckout("busy", uncommitted: 3))
        }
    }

    func test_createExisting_movesACleanMainCheckoutToTheDefaultBranch() throws {
        try GitFixture.run(["checkout", "-q", "-b", "busy"], in: repo)
        try GitFixture.write("committed\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "on busy"], in: repo)

        let worktree = try WorktreeStore.create(existingBranch: "busy", in: repo)

        XCTAssertEqual(worktree.branch, "busy")
        XCTAssertEqual(
            try GitFixture.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), "main",
            "the main checkout moved to the default branch, not a detached origin/main")
    }

    func test_createExisting_putsTheMainCheckoutBackWhenTheAddFails() throws {
        try GitFixture.run(["checkout", "-q", "-b", "busy"], in: repo)
        try GitFixture.run(["commit", "-q", "--allow-empty", "-m", "on busy"], in: repo)
        try failingPostCheckoutHook()

        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "busy", in: repo))

        XCTAssertEqual(
            try GitFixture.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), "busy",
            "the main checkout is back on the branch it started on")
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    func test_createExisting_refusesWhenTheDefaultBranchIsItselfInAWorktree() throws {
        try GitFixture.run(["checkout", "-q", "-b", "busy"], in: repo)
        _ = try WorktreeStore.create(existingBranch: "main", in: repo)

        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "busy", in: repo)) { error in
            XCTAssertEqual(
                error as? WorktreeStore.WorktreeError,
                .defaultBranchInWorktree("busy", defaultBranch: "main"))
        }
        XCTAssertEqual(try GitFixture.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), "busy")
    }

    func test_createExisting_refusesABranchNameGitWouldReadAsAnOption() throws {
        try GitFixture.run(["update-ref", "refs/heads/-m", "HEAD"], in: repo)

        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "-m", in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .invalidBranchName("-m"))
        }
    }

    func test_createExisting_leavesTheMainCheckoutPutWhenTheFolderIsOccupied() throws {
        try GitFixture.run(["checkout", "-q", "-b", "busy"], in: repo)
        try GitFixture.run(["commit", "-q", "--allow-empty", "-m", "on busy"], in: repo)
        let taken = WorktreeStore.rootOverrideForTesting!
            .appendingPathComponent(WorktreeStore.directoryName(for: repo), isDirectory: true)
            .appendingPathComponent(WorktreeStore.slug(forText: "busy"), isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)

        XCTAssertThrowsError(try WorktreeStore.create(existingBranch: "busy", in: repo))

        XCTAssertEqual(try GitFixture.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), "busy")
    }

    func test_holders_tellTheMainCheckoutFromAWorktree() throws {
        try GitFixture.run(["branch", "parked"], in: repo)
        let worktree = try WorktreeStore.create(existingBranch: "parked", in: repo)

        let holders = WorktreeStore.holders(in: repo)

        XCTAssertEqual(holders["main"], .mainCheckout(repo.resolvingSymlinksInPath().standardizedFileURL))
        XCTAssertEqual(holders["parked"], .worktree(worktree.path))
        XCTAssertNil(holders["nothing"])
    }

    func test_createOptions_carryTheHolders() throws {
        try GitFixture.run(["branch", "parked"], in: repo)

        let options = WorktreeStore.createOptions(in: repo)

        XCTAssertNotNil(options.holders["main"])
        XCTAssertNil(options.holders["parked"], "a branch checked out nowhere has no holder")
    }

    func test_list_isEmptyForARepoWithNoWorktrees() throws {
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    func test_list_excludesTheMainCheckout() throws {
        _ = try WorktreeStore.create(branch: "aaa-sorts-first", in: repo)

        let listed = try WorktreeStore.list(in: repo)

        XCTAssertEqual(listed.map(\.branch), ["aaa-sorts-first"])
        XCTAssertFalse(listed.contains { $0.path == repo.standardizedFileURL })
    }

    func test_list_reportsAWorktreeMadeByHandOutsideTheStore() throws {
        let elsewhere = root.appendingPathComponent("by-hand", isDirectory: true)
        try GitFixture.run(["worktree", "add", "-b", "hand", elsewhere.path], in: repo)

        let listed = try WorktreeStore.list(in: repo)

        XCTAssertEqual(listed.map(\.path), [elsewhere.standardizedFileURL])
        XCTAssertEqual(listed.first?.branch, "hand")
    }

    func test_list_reportsADetachedWorktreeWithNoBranch() throws {
        let detached = root.appendingPathComponent("detached", isDirectory: true)
        try GitFixture.run(["worktree", "add", "--detach", detached.path], in: repo)

        let listed = try WorktreeStore.list(in: repo)

        XCTAssertEqual(listed.count, 1)
        XCTAssertNil(listed.first?.branch)
        XCTAssertFalse(try XCTUnwrap(listed.first).head.isEmpty)
    }

    func test_list_forgetsAWorktreeDeletedInFinder() throws {
        let worktree = try WorktreeStore.create(branch: "gone", in: repo)
        try FileManager.default.removeItem(at: worktree.path)

        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
        let afterPrune = try GitFixture.run(["worktree", "list", "--porcelain"], in: repo)
        XCTAssertFalse(afterPrune.contains("prunable"), "the record was pruned, not just filtered")
    }

    func test_list_withoutPruning_leavesTheRecordAlone() throws {
        let worktree = try WorktreeStore.create(branch: "moved", in: repo)
        try FileManager.default.removeItem(at: worktree.path)

        XCTAssertEqual(try WorktreeStore.list(in: repo, pruning: false), [])

        let after = try GitFixture.run(["worktree", "list", "--porcelain"], in: repo)
        XCTAssertTrue(after.contains("prunable"), "the record survives a read")
    }

    func test_list_throwsForADirectoryThatIsNotARepo() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertThrowsError(try WorktreeStore.list(in: plain)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .notARepo(plain))
        }
    }

    func test_create_landsOnANewBranchOffTheRemoteDefault() throws {
        try GitFixture.run(["checkout", "-q", "-b", "trunk"], in: repo)
        try GitFixture.write("trunk\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "on trunk"], in: repo)
        try GitFixture.run(["push", "-q", "-u", "origin", "trunk"], in: repo)
        try GitFixture.run(["remote", "set-head", "origin", "trunk"], in: repo)
        try GitFixture.run(["checkout", "-q", "-b", "side"], in: repo)
        try GitFixture.write("side\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "on side"], in: repo)

        let worktree = try WorktreeStore.create(branch: "fresh", in: repo)

        XCTAssertEqual(worktree.branch, "fresh")
        XCTAssertEqual(
            worktree.head, try GitFixture.run(["rev-parse", "origin/trunk"], in: repo),
            "cut from origin/HEAD, not origin/main and not the checkout's own branch")
        XCTAssertEqual(
            try String(
                contentsOf: worktree.path.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "trunk\n")
    }

    func test_create_fromTheCurrentCheckout_cutsFromWhereTheRepoIsStanding() throws {
        try GitFixture.run(["checkout", "-q", "-b", "side"], in: repo)
        try GitFixture.write("side\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "on side"], in: repo)

        let worktree = try WorktreeStore.create(branch: "stacked", base: .currentCheckout, in: repo)

        XCTAssertEqual(worktree.head, try GitFixture.run(["rev-parse", "side"], in: repo))
        XCTAssertNotEqual(worktree.head, try GitFixture.run(["rev-parse", "origin/main"], in: repo))
    }

    func test_createOptions_nameTheRefsAndTheBranchesAlreadyTaken() throws {
        try GitFixture.run(["checkout", "-q", "-b", "side"], in: repo)

        let options = WorktreeStore.createOptions(in: repo)

        XCTAssertEqual(options.currentBranch, "side")
        XCTAssertEqual(options.defaultBase, "origin/main")
        XCTAssertTrue(options.branches.contains("side"))
        XCTAssertTrue(options.branches.contains("main"))
    }

    func test_createOptions_inARepoWithNoRemote_nameTheLocalBranchForBothChoices() throws {
        let solo = try GitFixture.makeRepo(at: root.appendingPathComponent("solo", isDirectory: true))

        let options = WorktreeStore.createOptions(in: solo)

        XCTAssertEqual(options.defaultBase, options.currentBranch)
        XCTAssertNotNil(options.defaultBase)
    }

    func test_create_fallsBackToOriginMainWhenOriginHeadIsUnset() throws {
        XCTAssertThrowsError(
            try GitFixture.run(["symbolic-ref", "refs/remotes/origin/HEAD"], in: repo))

        let worktree = try WorktreeStore.create(branch: "fallback", in: repo)

        XCTAssertEqual(worktree.head, try GitFixture.run(["rev-parse", "origin/main"], in: repo))
    }

    func test_create_fallsBackToLocalHeadInARepoWithNoRemote() throws {
        let solo = try GitFixture.makeRepo(at: root.appendingPathComponent("solo", isDirectory: true))

        let worktree = try WorktreeStore.create(branch: "local", in: solo)

        XCTAssertEqual(worktree.head, try GitFixture.run(["rev-parse", "HEAD"], in: solo))
        XCTAssertEqual(try WorktreeStore.list(in: solo).map(\.branch), ["local"])
    }

    func test_create_putsTheWorktreeUnderTheRepoDirectory() throws {
        let worktree = try WorktreeStore.create(branch: "feature/zen-452-thing", in: repo)

        XCTAssertEqual(worktree.path.lastPathComponent, "feature-zen-452-thing")
        XCTAssertEqual(
            worktree.path.deletingLastPathComponent().lastPathComponent,
            WorktreeStore.directoryName(for: repo))
    }

    func test_create_leavesTheNewBranchUntracked() throws {
        _ = try WorktreeStore.create(branch: "fresh", in: repo)

        XCTAssertThrowsError(try GitFixture.run(["config", "branch.fresh.merge"], in: repo))
        XCTAssertThrowsError(try GitFixture.run(["config", "branch.fresh.remote"], in: repo))
    }

    func test_create_refusesABranchThatAlreadyExists() throws {
        try GitFixture.run(["branch", "taken"], in: repo)

        XCTAssertThrowsError(try WorktreeStore.create(branch: "taken", in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .branchExists("taken"))
        }
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    func test_create_leavesNoBranchBehindWhenTheDestinationIsOccupied() throws {
        let parent = WorktreeStore.root.appendingPathComponent(
            WorktreeStore.directoryName(for: repo), isDirectory: true)
        let occupied = parent.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try GitFixture.write("", to: occupied.appendingPathComponent("squatter"))

        XCTAssertThrowsError(try WorktreeStore.create(branch: "blocked", in: repo)) { error in
            XCTAssertEqual(
                error as? WorktreeStore.WorktreeError, .destinationExists(occupied, branch: nil))
        }
        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"])
        XCTAssertTrue(GitFixture.exists(occupied.appendingPathComponent("squatter")))
    }

    func test_create_rollsTheBranchBackWhenTheFolderCannotBeMade() throws {
        let parent = WorktreeStore.root.appendingPathComponent(
            WorktreeStore.directoryName(for: repo), isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }

        XCTAssertThrowsError(try WorktreeStore.create(branch: "wedged", in: repo))
        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"])
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    func test_create_throwsWhenTheRepoHasNoCommits() throws {
        let empty = try GitFixture.makeEmptyRepo(at: root.appendingPathComponent("empty"))

        XCTAssertThrowsError(try WorktreeStore.create(branch: "first", in: empty)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .unbornHead(empty))
        }
        XCTAssertEqual(try GitFixture.branches(in: empty), [])
    }

    func test_create_throwsForADirectoryThatIsNotARepo() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertThrowsError(try WorktreeStore.create(branch: "x", in: plain)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .notARepo(plain))
        }
    }

    func test_create_refusesABranchNameThatGitWouldReadAsAnOption() throws {
        let headBefore = try GitFixture.run(["symbolic-ref", "HEAD"], in: repo)

        XCTAssertThrowsError(try WorktreeStore.create(branch: "-m", in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .invalidBranchName("-m"))
        }
        XCTAssertEqual(try GitFixture.run(["symbolic-ref", "HEAD"], in: repo), headBefore)
        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"])
    }

    func test_create_refusesANameGitWouldNotTake() throws {
        for name in ["bad..name", "has space", "ends.lock", ""] {
            XCTAssertThrowsError(try WorktreeStore.create(branch: name, in: repo), name) { error in
                XCTAssertEqual(error as? WorktreeStore.WorktreeError, .invalidBranchName(name), name)
            }
        }
        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"])
    }

    func test_create_rollbackClearsTheRegistrationSoNoOrphanSurvives() throws {
        try failingPostCheckoutHook()

        XCTAssertThrowsError(try WorktreeStore.create(branch: "hooked", in: repo))

        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"], "no orphaned branch")
        XCTAssertFalse(
            GitFixture.exists(repo.appendingPathComponent(".git/worktrees/hooked")),
            "no stale admin entry")
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    func test_create_leavesABranchItDidNotCreateAlone() throws {
        var theirCommit = ""
        WorktreeStore.beforeClaimingForTesting = { repo in
            try? GitFixture.run(["branch", "raced"], in: repo)
            let commit = try? GitFixture.run(
                ["commit-tree", "-m", "their work", "-p", "HEAD", "HEAD^{tree}"], in: repo)
            try? GitFixture.run(["update-ref", "refs/heads/raced", commit ?? ""], in: repo)
            theirCommit = (try? GitFixture.run(["rev-parse", "raced"], in: repo)) ?? ""
        }

        XCTAssertThrowsError(try WorktreeStore.create(branch: "raced", in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .branchExists("raced"))
        }
        XCTAssertEqual(try GitFixture.run(["rev-parse", "raced"], in: repo), theirCommit)
    }

    func test_create_leavesABranchRacedOntoTheSameBaseAlone() throws {
        WorktreeStore.beforeClaimingForTesting = { repo in
            try? GitFixture.run(["branch", "raced", "origin/main"], in: repo)
        }

        XCTAssertThrowsError(try WorktreeStore.create(branch: "raced", in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .branchExists("raced"))
        }
        XCTAssertEqual(
            try GitFixture.run(["rev-parse", "raced"], in: repo),
            try GitFixture.run(["rev-parse", "origin/main"], in: repo))
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    func test_create_leavesABranchTheAddMovedBehind() throws {
        try hook("post-checkout", "#!/bin/sh\ngit commit -q --allow-empty -m theirs\nexit 1\n")

        XCTAssertThrowsError(try WorktreeStore.create(branch: "moved", in: repo)) { error in
            guard
                case .rollbackIncomplete(_, let leftBehind) =
                    try? XCTUnwrap(error as? WorktreeStore.WorktreeError)
            else { return XCTFail("expected rollbackIncomplete, got \(error)") }
            XCTAssertEqual(leftBehind, ["the branch moved"])
        }
        XCTAssertEqual(
            try GitFixture.run(["log", "-1", "--format=%s", "moved"], in: repo), "theirs")
    }

    func test_create_leavesAFolderItDidNotMakeAlone() throws {
        let parent = WorktreeStore.root.appendingPathComponent(
            WorktreeStore.directoryName(for: repo), isDirectory: true)
        let theirs = parent.appendingPathComponent("raced", isDirectory: true)
        WorktreeStore.beforeClaimingForTesting = { _ in
            try? FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
            try? GitFixture.write("theirs\n", to: theirs.appendingPathComponent("tracked.txt"))
        }

        XCTAssertThrowsError(try WorktreeStore.create(branch: "raced", in: repo)) { error in
            XCTAssertEqual(
                error as? WorktreeStore.WorktreeError, .destinationExists(theirs, branch: nil))
        }
        XCTAssertTrue(GitFixture.exists(theirs.appendingPathComponent("tracked.txt")))
        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"], "our claim was given back")
    }

    func test_remove_deletesAWorktreeHoldingUntrackedFiles() throws {
        let worktree = try WorktreeStore.create(branch: "doomed", in: repo)
        try GitFixture.write("local\n", to: worktree.path.appendingPathComponent(".env"))
        try GitFixture.write("edit\n", to: worktree.path.appendingPathComponent("tracked.txt"))

        try WorktreeStore.remove(worktree, in: repo)

        XCTAssertFalse(GitFixture.exists(worktree.path))
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    func test_remove_refusesALockedWorktree() throws {
        let created = try WorktreeStore.create(branch: "pinned", in: repo)
        try GitFixture.run(["worktree", "lock", created.path.path], in: repo)
        let worktree = try XCTUnwrap(try WorktreeStore.list(in: repo).first)

        XCTAssertTrue(worktree.isLocked)
        XCTAssertThrowsError(try WorktreeStore.remove(worktree, in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .isLocked(worktree.path))
        }
        XCTAssertTrue(GitFixture.exists(created.path))
    }

    func test_remove_leavesTheBranchAlone() throws {
        let worktree = try WorktreeStore.create(branch: "survivor", in: repo)

        try WorktreeStore.remove(worktree, in: repo)

        XCTAssertEqual(try GitFixture.branches(in: repo), ["main", "survivor"])
    }

    func test_state_ofAFreshWorktreeIsClean() throws {
        let worktree = try WorktreeStore.create(branch: "clean", in: repo)

        XCTAssertEqual(WorktreeStore.state(worktree), WorktreeState(files: [], detachedCommits: 0))
        XCTAssertEqual(WorktreeStore.state(worktree)?.isClean, true)
    }

    func test_state_listsEachFileWithItsStatus() throws {
        let worktree = try WorktreeStore.create(branch: "busy", in: repo)
        try GitFixture.write("changed\n", to: worktree.path.appendingPathComponent("tracked.txt"))
        try GitFixture.write("staged\n", to: worktree.path.appendingPathComponent("staged file.txt"))
        try GitFixture.run(["add", "staged file.txt"], in: worktree.path)
        try GitFixture.write("new\n", to: worktree.path.appendingPathComponent("untracked.txt"))

        let state = try XCTUnwrap(WorktreeStore.state(worktree))

        XCTAssertEqual(
            state.files.sorted { $0.path < $1.path },
            [
                WorktreeFileChange(path: "staged file.txt", categories: [.staged]),
                WorktreeFileChange(path: "tracked.txt", categories: [.modified]),
                WorktreeFileChange(path: "untracked.txt", categories: [.untracked]),
            ])
        XCTAssertEqual(state.uncommitted, 3)
    }

    func test_state_neverCountsCommitsOnABranch() throws {
        let worktree = try WorktreeStore.create(branch: "local-work", in: repo)
        try GitFixture.write("committed\n", to: worktree.path.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "unpushed"], in: worktree.path)

        let state = try XCTUnwrap(WorktreeStore.state(worktree))

        XCTAssertEqual(state.detachedCommits, 0)
        XCTAssertTrue(state.isClean)
    }

    func test_state_countsCommitsOnlyADetachedHeadHolds() throws {
        let detached = root.appendingPathComponent("detached", isDirectory: true)
        try GitFixture.run(["worktree", "add", "--detach", detached.path], in: repo)
        let worktree = Worktree(path: detached, branch: nil, head: "", isLocked: false)
        XCTAssertEqual(WorktreeStore.state(worktree)?.detachedCommits, 0, "a HEAD still on main holds nothing alone")

        for message in ["second", "third"] {
            try GitFixture.write("\(message)\n", to: detached.appendingPathComponent("tracked.txt"))
            try GitFixture.run(["commit", "-qam", message], in: detached)
        }

        XCTAssertEqual(WorktreeStore.state(worktree)?.detachedCommits, 2)

        try GitFixture.run(["branch", "kept"], in: detached)
        XCTAssertEqual(WorktreeStore.state(worktree)?.detachedCommits, 0, "a local branch holds them now")
    }

    func test_state_listsEveryFileInAnUntrackedDirectory() throws {
        let worktree = try WorktreeStore.create(branch: "untracked-dir", in: repo)
        let nested = worktree.path.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] {
            try GitFixture.write("x\n", to: nested.appendingPathComponent(name))
        }

        let state = try XCTUnwrap(WorktreeStore.state(worktree))

        XCTAssertEqual(state.files.map(\.path).sorted(), ["scratch/a.txt", "scratch/b.txt", "scratch/c.txt"])
    }

    func test_state_isNilWhenTheWorktreeCannotBeRead() throws {
        let worktree = try WorktreeStore.create(branch: "vanished", in: repo)
        try FileManager.default.removeItem(at: worktree.path)

        XCTAssertNil(WorktreeStore.state(worktree))
    }

    func test_list_readsAWorktreeWhosePathHoldsANewline() throws {
        let odd = root.appendingPathComponent("by\nhand", isDirectory: true)
        try GitFixture.run(["worktree", "add", "-b", "odd", odd.path], in: repo)

        let listed = try WorktreeStore.list(in: repo)

        XCTAssertEqual(listed.map(\.path), [odd.standardizedFileURL])
        XCTAssertEqual(listed.first?.branch, "odd")
    }

    func test_create_fallsBackWhenOriginHeadNamesAMissingBranch() throws {
        try GitFixture.run(
            ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], in: repo)

        let worktree = try WorktreeStore.create(branch: "recovered", in: repo)

        XCTAssertEqual(
            try GitFixture.run(["rev-parse", "HEAD"], in: worktree.path),
            try GitFixture.run(["rev-parse", "origin/main"], in: repo))
    }

    func test_commonDir_isTheSameForACheckoutAndItsWorktree() throws {
        let worktree = try WorktreeStore.create(branch: "feature", in: repo)

        XCTAssertEqual(WorktreeStore.commonDir(of: repo), WorktreeStore.commonDir(of: worktree.path))
        XCTAssertEqual(
            WorktreeStore.commonDir(of: repo),
            repo.appendingPathComponent(".git").resolvingSymlinksInPath().standardizedFileURL)
    }

    func test_commonDir_matchesAHandMadeWorktreeAnywhere() throws {
        let elsewhere = root.appendingPathComponent("by-hand", isDirectory: true)
        try GitFixture.run(["worktree", "add", "-b", "by-hand", elsewhere.path], in: repo)

        XCTAssertEqual(WorktreeStore.commonDir(of: elsewhere), WorktreeStore.commonDir(of: repo))
    }

    func test_commonDir_separatesASubmoduleFromItsSuperproject() throws {
        let sub = try makeSubmodule()

        let answer = WorktreeStore.commonDir(of: sub)
        XCTAssertNotNil(answer)
        XCTAssertNotEqual(answer, WorktreeStore.commonDir(of: repo))
    }

    func test_commonDir_isNilOutsideARepo() throws {
        let plain = root.appendingPathComponent("not-a-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertNil(WorktreeStore.commonDir(of: plain))
    }

    func test_shouldPrune_refusesAPrunableWorktreeOnAnAbsentVolume() {
        let absent = "/Volumes/\(UUID().uuidString)/code/wt"

        XCTAssertFalse(WorktreeStore.shouldPrune(prunableListing(for: absent)))
    }

    func test_shouldPrune_allowsAPrunableWorktreeOnThisVolume() {
        let here = root.appendingPathComponent("deleted", isDirectory: true).path

        XCTAssertTrue(WorktreeStore.shouldPrune(prunableListing(for: here)))
    }

    func test_shouldPrune_allowsAPrunableWorktreeOnAMountedVolume() throws {
        let mounted = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: "/Volumes").first)

        XCTAssertTrue(WorktreeStore.shouldPrune(prunableListing(for: "/Volumes/\(mounted)/wt")))
    }

    func test_shouldPrune_isFalseWhenNothingIsPrunable() throws {
        let listing = try GitFixture.run(["worktree", "list", "--porcelain", "-z"], in: repo)

        XCTAssertFalse(WorktreeStore.shouldPrune(listing))
    }

    private func prunableListing(for path: String) -> String {
        let zeros = String(repeating: "0", count: 40)
        let main = ["worktree \(repo.path)", "HEAD \(zeros)", "branch refs/heads/main"]
        let stale = [
            "worktree \(path)", "HEAD \(zeros)",
            "prunable gitdir file points to non-existent location",
        ]
        return [main, stale].map { $0.joined(separator: "\0") }.joined(separator: "\0\0")
    }

    func test_list_isEmptyInsideASubmodule() throws {
        let sub = try makeSubmodule()

        XCTAssertTrue(GitRepo.isGitRepo(sub), "a submodule is reachable through the picker")
        XCTAssertEqual(try WorktreeStore.list(in: sub), [])
    }

    func test_create_fromInsideAWorktreeUsesTheRepoOneHome() throws {
        let first = try WorktreeStore.create(branch: "one", in: repo)

        let second = try WorktreeStore.create(branch: "two", in: first.path)

        XCTAssertEqual(
            second.path.deletingLastPathComponent().lastPathComponent,
            WorktreeStore.directoryName(for: repo))
        XCTAssertEqual(try WorktreeStore.list(in: repo).compactMap(\.branch).sorted(), ["one", "two"])
    }

    private func makeSubmodule() throws -> URL {
        let lib = try GitFixture.makeRepo(at: root.appendingPathComponent("lib", isDirectory: true))
        try GitFixture.run(
            ["-c", "protocol.file.allow=always", "submodule", "add", "--quiet", lib.path, "sub"],
            in: repo)
        try GitFixture.run(["commit", "-qm", "add submodule"], in: repo)
        return repo.appendingPathComponent("sub", isDirectory: true)
    }

    func test_create_rollsBackABranchCutFromABaseAheadOfTheCheckout() throws {
        try GitFixture.write("two\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "second"], in: repo)
        try GitFixture.run(["push", "-q", "origin", "main"], in: repo)
        try GitFixture.run(["reset", "--hard", "--quiet", "HEAD~1"], in: repo)
        try failingPostCheckoutHook()

        XCTAssertThrowsError(try WorktreeStore.create(branch: "behind", in: repo))

        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"], "no orphaned branch")
    }

    func test_create_namesTheBranchAlreadyHoldingTheFolder() throws {
        _ = try WorktreeStore.create(branch: "feature/x", in: repo)

        XCTAssertThrowsError(try WorktreeStore.create(branch: "feature-x", in: repo)) { error in
            guard case .destinationExists(_, let branch) = error as? WorktreeStore.WorktreeError
            else { return XCTFail("expected destinationExists, got \(error)") }
            XCTAssertEqual(branch, "feature/x")
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "A worktree for feature/x already uses that folder name.")
        }
        XCTAssertEqual(try GitFixture.branches(in: repo), ["feature/x", "main"])
    }

    private func failingPostCheckoutHook() throws {
        try hook("post-checkout", "#!/bin/sh\nexit 1\n")
    }

    private func hook(_ name: String, _ script: String) throws {
        let path = repo.appendingPathComponent(".git/hooks/\(name)")
        try GitFixture.write(script, to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func test_directoryName_differsForReposWhoseFoldersShareAName() throws {
        let one = root.appendingPathComponent("a/app", isDirectory: true)
        let two = root.appendingPathComponent("b/app", isDirectory: true)

        XCTAssertTrue(WorktreeStore.directoryName(for: one).hasPrefix("app-"))
        XCTAssertNotEqual(
            WorktreeStore.directoryName(for: one), WorktreeStore.directoryName(for: two))
    }

    func test_slug_makesOnePathSegmentFromABranchName() {
        XCTAssertEqual(WorktreeStore.slug(forText: "feature/zen-452"), "feature-zen-452")
        XCTAssertEqual(WorktreeStore.slug(forText: "Fix: The Thing"), "fix-the-thing")
        XCTAssertEqual(WorktreeStore.slug(forText: "///"), "worktree")
    }
}
