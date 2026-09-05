import XCTest

@testable import ZenTerm

/// The headless worktree layer behind the ⌘P picker's worktree rows. Real git repositories in a
/// temp directory, because everything this covers is git's behaviour and not our own bookkeeping.
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
        WorktreeStore.betweenCheckAndAddForTesting = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: list

    func test_list_isEmptyForARepoWithNoWorktrees() throws {
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    /// The picker's workspace row *is* the main checkout, so returning it would double every repo.
    /// `worktree list` documents record one as the main worktree, and a linked one sorting ahead
    /// of it is what catches an implementation that trusts the order instead.
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

    /// The ghost row the clone approach had to solve by hand: git keeps the admin record after the
    /// directory goes, and reports it as prunable until something prunes it.
    func test_list_forgetsAWorktreeDeletedInFinder() throws {
        let worktree = try WorktreeStore.create(branch: "gone", in: repo)
        try FileManager.default.removeItem(at: worktree.path)

        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
        let afterPrune = try GitFixture.run(["worktree", "list", "--porcelain"], in: repo)
        XCTAssertFalse(afterPrune.contains("prunable"), "the record was pruned, not just filtered")
    }

    func test_list_throwsForADirectoryThatIsNotARepo() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertThrowsError(try WorktreeStore.list(in: plain)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .notARepo(plain))
        }
    }

    // MARK: create

    /// Origin's default here is `trunk`, not `main`, so the `origin/HEAD` rung is the only one
    /// that gives this answer: the `origin/main` fallback points at a different commit.
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

    /// A repo that was `git init`ed locally and pushed has no `refs/remotes/origin/HEAD` at all.
    func test_create_fallsBackToOriginMainWhenOriginHeadIsUnset() throws {
        XCTAssertThrowsError(
            try GitFixture.run(["symbolic-ref", "refs/remotes/origin/HEAD"], in: repo))

        let worktree = try WorktreeStore.create(branch: "fallback", in: repo)

        XCTAssertEqual(worktree.head, try GitFixture.run(["rev-parse", "origin/main"], in: repo))
    }

    /// The clone approach refused a repo with no remote outright. A worktree does not need one.
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

    func test_create_refusesABranchThatAlreadyExists() throws {
        try GitFixture.run(["branch", "taken"], in: repo)

        XCTAssertThrowsError(try WorktreeStore.create(branch: "taken", in: repo)) { error in
            XCTAssertEqual(error as? WorktreeStore.WorktreeError, .branchExists("taken"))
        }
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    /// Probed against git 2.50.1: `worktree add` creates the branch *before* it checks the
    /// destination, so a failure here leaves a branch with no tree on it unless create takes it back.
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

    /// The precheck above never reaches git. This one does: the parent directory is read-only, so
    /// `worktree add` creates the branch and then fails to make the tree.
    func test_create_rollsTheBranchBackWhenGitCannotMakeTheTree() throws {
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

    // MARK: create, the destructive failure paths

    /// `worktree add -b <name>` reaches git's own `git branch` call with no `--` guard, so a name
    /// beginning with a dash is read as an option there. `-m` renames the checked-out branch.
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

    /// A `post-checkout` hook that fails (direnv, LFS, repo tooling) makes `worktree add` register
    /// the worktree and *then* exit non-zero. Deleting the directory first leaves git refusing to
    /// drop the branch, with a stale admin entry that breaks the next create of the same name.
    func test_create_rollbackClearsTheRegistrationSoNoOrphanSurvives() throws {
        try failingPostCheckoutHook()

        XCTAssertThrowsError(try WorktreeStore.create(branch: "hooked", in: repo))

        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"], "no orphaned branch")
        XCTAssertFalse(
            GitFixture.exists(repo.appendingPathComponent(".git/worktrees/hooked")),
            "no stale admin entry")
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    /// Isolates the OID guard. The raced branch sits on an older commit that IS merged, so
    /// `branch -d` would delete it without complaint and only the OID comparison can save it.
    func test_create_doesNotDeleteAMergedBranchItDidNotCreate() throws {
        let older = try GitFixture.run(["rev-parse", "HEAD"], in: repo)
        try GitFixture.write("two\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "second"], in: repo)
        try GitFixture.run(["push", "-q", "origin", "main"], in: repo)
        WorktreeStore.betweenCheckAndAddForTesting = { repo in
            try? GitFixture.run(["branch", "raced", older], in: repo)
        }

        XCTAssertThrowsError(try WorktreeStore.create(branch: "raced", in: repo)) { error in
            guard
                case .rollbackIncomplete(_, let leftBehind) =
                    try? XCTUnwrap(error as? WorktreeStore.WorktreeError)
            else { return XCTFail("expected rollbackIncomplete, got \(error)") }
            XCTAssertEqual(leftBehind, ["the branch raced"])
        }
        XCTAssertEqual(try GitFixture.run(["rev-parse", "raced"], in: repo), older, "untouched")
    }

    /// The same window with an unmerged branch. The rollback deletes with `-D`, so nothing but
    /// the OID guard stands between someone else's commits and a delete.
    func test_create_doesNotDeleteAnUnmergedBranchItDidNotCreate() throws {
        var theirCommit = ""
        WorktreeStore.betweenCheckAndAddForTesting = { repo in
            try? GitFixture.run(["branch", "raced"], in: repo)
            let commit = try? GitFixture.run(
                ["commit-tree", "-m", "their work", "-p", "HEAD", "HEAD^{tree}"], in: repo)
            try? GitFixture.run(["update-ref", "refs/heads/raced", commit ?? ""], in: repo)
            theirCommit = (try? GitFixture.run(["rev-parse", "raced"], in: repo)) ?? ""
        }

        XCTAssertThrowsError(try WorktreeStore.create(branch: "raced", in: repo))
        XCTAssertEqual(try GitFixture.run(["rev-parse", "raced"], in: repo), theirCommit)
    }

    /// The residual the OID guard cannot close, pinned rather than papered over: a raced branch cut
    /// from the same base is indistinguishable from ours, so the rollback takes it. It carries no
    /// commits of its own, so the loss is the ref and nothing else.
    func test_create_takesBackABranchStandingExactlyWhereItPutIt() throws {
        WorktreeStore.betweenCheckAndAddForTesting = { repo in
            try? GitFixture.run(["branch", "raced", "origin/main"], in: repo)
        }

        XCTAssertThrowsError(try WorktreeStore.create(branch: "raced", in: repo)) { error in
            if case .rollbackIncomplete = error as? WorktreeStore.WorktreeError {
                XCTFail("the rollback should complete cleanly here")
            }
        }
        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"])
    }

    // MARK: remove

    /// Carried files (ZEN-453) are always untracked, and git refuses a worktree holding those
    /// without `--force`, so the force is unconditional rather than a fallback.
    func test_remove_deletesAWorktreeHoldingUntrackedFiles() throws {
        let worktree = try WorktreeStore.create(branch: "doomed", in: repo)
        try GitFixture.write("local\n", to: worktree.path.appendingPathComponent(".env"))
        try GitFixture.write("edit\n", to: worktree.path.appendingPathComponent("tracked.txt"))

        try WorktreeStore.remove(worktree, in: repo)

        XCTAssertFalse(GitFixture.exists(worktree.path))
        XCTAssertEqual(try WorktreeStore.list(in: repo), [])
    }

    /// A lock is the user's own "not this one", usually because the worktree lives on a drive that
    /// comes and goes. `--force` alone cannot remove it anyway: git wants the force twice.
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

    // MARK: state

    func test_state_ofAFreshWorktreeIsClean() throws {
        let worktree = try WorktreeStore.create(branch: "clean", in: repo)

        XCTAssertEqual(WorktreeStore.state(worktree), WorktreeState(uncommitted: 0, unpushed: 0))
        XCTAssertEqual(WorktreeStore.state(worktree)?.isClean, true)
    }

    func test_state_countsUncommittedAndUnpushed() throws {
        let worktree = try WorktreeStore.create(branch: "busy", in: repo)
        try GitFixture.write("changed\n", to: worktree.path.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "one"], in: worktree.path)
        try GitFixture.write("again\n", to: worktree.path.appendingPathComponent("tracked.txt"))
        try GitFixture.write("new\n", to: worktree.path.appendingPathComponent("untracked.txt"))

        let state = try XCTUnwrap(WorktreeStore.state(worktree))

        XCTAssertEqual(state.uncommitted, 2)
        XCTAssertEqual(state.unpushed, 1)
        XCTAssertFalse(state.isClean)
    }

    /// `--not --remotes` excludes nothing when there are no remote-tracking refs, so the count is
    /// the repo's whole history. A local-only worktree would never read as clean.
    func test_state_countsNothingUnpushedInARepoWithNoRemote() throws {
        let solo = try GitFixture.makeRepo(at: root.appendingPathComponent("solo"))
        try GitFixture.write("two\n", to: solo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "second"], in: solo)
        let worktree = try WorktreeStore.create(branch: "local-only", in: solo)

        let state = try XCTUnwrap(WorktreeStore.state(worktree))

        XCTAssertEqual(state.unpushed, 0)
        XCTAssertTrue(state.isClean)
    }

    /// Nil is not "clean". Reporting zero here would tell someone about to delete an unreadable
    /// tree that it holds nothing.
    func test_state_isNilWhenTheWorktreeCannotBeRead() throws {
        let worktree = try WorktreeStore.create(branch: "vanished", in: repo)
        try FileManager.default.removeItem(at: worktree.path)

        XCTAssertNil(WorktreeStore.state(worktree))
    }

    /// Git escapes a lock reason but never the path, so a worktree whose directory holds a newline
    /// splits a line-based parse across records. Nothing we make can, one added by hand can.
    func test_list_readsAWorktreeWhosePathHoldsANewline() throws {
        let odd = root.appendingPathComponent("by\nhand", isDirectory: true)
        try GitFixture.run(["worktree", "add", "-b", "odd", odd.path], in: repo)

        let listed = try WorktreeStore.list(in: repo)

        XCTAssertEqual(listed.map(\.path), [odd.standardizedFileURL])
        XCTAssertEqual(listed.first?.branch, "odd")
    }

    /// `symbolic-ref` still succeeds when `origin/HEAD` names a branch the remote no longer has, so
    /// an unverified base reaches `rev-parse` and kills the create instead of falling through.
    func test_create_fallsBackWhenOriginHeadNamesAMissingBranch() throws {
        try GitFixture.run(
            ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], in: repo)

        let worktree = try WorktreeStore.create(branch: "recovered", in: repo)

        XCTAssertEqual(
            try GitFixture.run(["rev-parse", "HEAD"], in: worktree.path),
            try GitFixture.run(["rev-parse", "origin/main"], in: repo))
    }

    // MARK: the volume a prunable worktree lives on

    /// A worktree on an unmounted volume is indistinguishable from a deleted one, and pruning its
    /// record is final: `worktree repair` cannot rebuild an admin file that is gone.
    func test_isSafeToPrune_refusesAPrunableWorktreeOnAnAbsentVolume() {
        let absent = "/Volumes/\(UUID().uuidString)/code/wt"

        XCTAssertFalse(WorktreeStore.isSafeToPrune(prunableListing(for: absent)))
    }

    func test_isSafeToPrune_allowsAPrunableWorktreeOnThisVolume() {
        let here = root.appendingPathComponent("deleted", isDirectory: true).path

        XCTAssertTrue(WorktreeStore.isSafeToPrune(prunableListing(for: here)))
    }

    /// The mount point itself is what disappears with the drive, so a volume that IS mounted keeps
    /// its worktrees prunable however deep under `/Volumes` they sit.
    func test_isSafeToPrune_allowsAPrunableWorktreeOnAMountedVolume() throws {
        let mounted = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: "/Volumes").first)

        XCTAssertTrue(WorktreeStore.isSafeToPrune(prunableListing(for: "/Volumes/\(mounted)/wt")))
    }

    /// The `-z` shape `worktree list` emits: fields NUL-separated, records by an empty field.
    private func prunableListing(for path: String) -> String {
        let zeros = String(repeating: "0", count: 40)
        let main = ["worktree \(repo.path)", "HEAD \(zeros)", "branch refs/heads/main"]
        let stale = [
            "worktree \(path)", "HEAD \(zeros)",
            "prunable gitdir file points to non-existent location",
        ]
        return [main, stale].map { $0.joined(separator: "\0") }.joined(separator: "\0\0")
    }

    // MARK: a repo that is not the main checkout

    /// Inside a submodule `--git-common-dir` is `<super>/.git/modules/<name>`, and `worktree list`
    /// reports that same internals path as the checkout. Deriving the main checkout from the common
    /// dir matches neither, so the submodule's own record survives as a row pointing into `.git`.
    func test_list_isEmptyInsideASubmodule() throws {
        let sub = try makeSubmodule()

        XCTAssertTrue(GitRepo.isGitRepo(sub), "a submodule is reachable through the picker")
        XCTAssertEqual(try WorktreeStore.list(in: sub), [])
    }

    /// Creating from inside a worktree has to land in the repo's one home. Keying the parent on the
    /// path it was handed gives the same repo a second directory under the root.
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

    // MARK: a base ahead of the checkout

    /// `-d` refuses a branch merged into neither its upstream nor the *current* HEAD. `worktree
    /// add -b` off a remote-tracking base normally sets that upstream and hides it, but not under
    /// `branch.autoSetupMerge=false`: there a checkout behind `origin/main` keeps the branch, and
    /// the orphan then wedges the next create of the same name. The OID guard is the real check.
    func test_create_rollsBackABranchCutFromABaseAheadOfTheCheckout() throws {
        try GitFixture.run(["config", "branch.autoSetupMerge", "false"], in: repo)
        try GitFixture.write("two\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["commit", "-qam", "second"], in: repo)
        try GitFixture.run(["push", "-q", "origin", "main"], in: repo)
        try GitFixture.run(["reset", "--hard", "--quiet", "HEAD~1"], in: repo)
        try failingPostCheckoutHook()

        XCTAssertThrowsError(try WorktreeStore.create(branch: "behind", in: repo))

        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"], "no orphaned branch")
    }

    // MARK: two branch names, one folder

    /// `feature/x` and `feature-x` slug onto one folder. Naming the folder would put a name the
    /// user never typed in front of them, with nothing connecting it to the branch they asked for.
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

    // MARK: fixtures

    /// A hook that fails after the checkout, the way direnv or an LFS hook can.
    private func failingPostCheckoutHook() throws {
        let hook = repo.appendingPathComponent(".git/hooks/post-checkout")
        try GitFixture.write("#!/bin/sh\nexit 1\n", to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    // MARK: naming

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
