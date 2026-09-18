import XCTest

@testable import ZenTerm

final class GitRepoStatusTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        GitRepoStatus.resetForTesting()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-gitstatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        GitRepoStatus.resetForTesting()
        GitRepo.homeOverrideForTesting = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func test_refresh_answersASubdirectoryOfARepoWithTheRepoBranch() throws {
        let repo = try GitFixture.makeRepo(at: root.appendingPathComponent("mono", isDirectory: true))
        let package = repo.appendingPathComponent("apps/rails", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        refresh([package])

        XCTAssertEqual(GitRepoStatus.known(package), true, "a package inside a monorepo is in a repo")
        XCTAssertEqual(GitRepoStatus.branch(package), "main")
        XCTAssertEqual(GitRepoStatus.repoRoot(package)?.path, repo.standardizedFileURL.path)
    }

    func test_refresh_refusesAPlainFolderUnderARepoAtHome() throws {
        GitRepo.homeOverrideForTesting = root
        _ = try GitFixture.makeRepo(at: root)
        let plain = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        refresh([plain])

        XCTAssertEqual(GitRepoStatus.known(plain), false, "dotfiles at home light up nothing")
        XCTAssertNil(GitRepoStatus.branch(plain))
        XCTAssertNil(GitRepoStatus.repoRoot(plain))
    }

    func test_refreshChurn_isNilForAPlainFolderUnderARepoAtHome() throws {
        GitRepo.homeOverrideForTesting = root
        _ = try GitFixture.makeRepo(at: root)
        let plain = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try GitFixture.write("loose\n", to: root.appendingPathComponent("untracked.txt"))

        var landed = 0
        GitRepoStatus.refreshChurn([plain]) { landed += 1 }
        waitUntil(landed == 1, "the probe to land")

        XCTAssertNil(GitRepoStatus.churn(plain), "home's churn is not this folder's")
    }

    func test_refreshChurn_countsTheWholeRepoFromASubdirectory() throws {
        let repo = try GitFixture.makeRepo(at: root.appendingPathComponent("mono", isDirectory: true))
        let package = repo.appendingPathComponent("apps/rails", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try GitFixture.write("loose\n", to: repo.appendingPathComponent("elsewhere.txt"))

        var landed = 0
        GitRepoStatus.refreshChurn([package]) { landed += 1 }
        waitUntil(landed == 1, "the probe to land")

        XCTAssertEqual(GitRepoStatus.churn(package)?.untracked, 1, "counts are repo-wide, as git reports them")
    }

    func test_refreshWorktrees_deliversTheCommonDirAndLinkedWorktreesOnMain() throws {
        let repo = try GitFixture.makeRepo(at: root.appendingPathComponent("work", isDirectory: true))
        try GitFixture.run(
            ["worktree", "add", "-b", "probe", root.appendingPathComponent("wt").path], in: repo)

        var answered: (dir: URL, listing: WorktreeListing)?
        var onMain = false
        let landed = expectation(description: "the listing lands")
        GitRepoStatus.refreshWorktrees([repo]) { dir, listing in
            onMain = Thread.isMainThread
            answered = (dir, listing)
            landed.fulfill()
        }
        wait(for: [landed], timeout: 20)

        XCTAssertTrue(onMain, "the cache and the rows are main-thread only")
        XCTAssertEqual(answered?.dir, repo.standardizedFileURL)
        XCTAssertEqual(answered?.listing.worktrees.compactMap(\.branch), ["probe"])
        XCTAssertEqual(answered?.listing.commonDir, WorktreeStore.commonDir(of: repo))
    }

    func test_refreshWorktrees_answersForADirectoryThatIsNotARepo() throws {
        let plain = try makeDir("plain", git: false)

        var listing: WorktreeListing?
        let landed = expectation(description: "the listing lands")
        GitRepoStatus.refreshWorktrees([plain]) { _, answer in
            listing = answer
            landed.fulfill()
        }
        wait(for: [landed], timeout: 20)

        XCTAssertEqual(listing?.worktrees, [])
        XCTAssertNil(listing?.commonDir)
    }

    func test_refreshWorktrees_aSecondCallerDoesNotCancelTheFirstsProbes() throws {
        let dirs = try (1...6).map { try makeDir("first-\($0)", git: false) }
        let other = try makeDir("second", git: false)

        var answered: Set<URL> = []
        let allLanded = expectation(description: "every directory answers")
        allLanded.expectedFulfillmentCount = dirs.count
        GitRepoStatus.refreshWorktrees(dirs) { dir, _ in
            answered.insert(dir)
            allLanded.fulfill()
        }
        GitRepoStatus.refreshWorktrees([other]) { _, _ in }

        wait(for: [allLanded], timeout: 20)
        XCTAssertEqual(answered, Set(dirs.map(\.standardizedFileURL)))
    }

    private func makeDir(_ name: String, git: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if git { try Data().write(to: dir.appendingPathComponent(".git")) }
        return dir
    }

    private func makeRepo(_ name: String, on branch: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let gitDir = dir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
        return dir
    }

    private func refresh(_ dirs: [URL]) {
        var landed = 0
        GitRepoStatus.refresh(dirs) { landed += 1 }
        waitUntil(landed == dirs.count, "every probe to land")
    }

    func test_known_isNilUntilSomethingProbes() throws {
        let repo = try makeDir("repo", git: true)
        XCTAssertNil(GitRepoStatus.known(repo))
    }

    func test_refresh_answersRepoAndPlainDirectories() throws {
        let repo = try makeDir("repo", git: true)
        let plain = try makeDir("plain", git: false)

        refresh([repo, plain])

        XCTAssertEqual(GitRepoStatus.known(repo), true)
        XCTAssertEqual(GitRepoStatus.known(plain), false)
    }

    func test_refresh_answersTheBranchAlongsideTheRepoAnswer() throws {
        let repo = try makeRepo("repo", on: "feature/zen-450")
        let plain = try makeDir("plain", git: false)

        refresh([repo, plain])

        XCTAssertEqual(GitRepoStatus.branch(repo), "feature/zen-450")
        XCTAssertNil(GitRepoStatus.branch(plain))
    }

    func test_refresh_picksUpASwitchedBranch() throws {
        let repo = try makeRepo("repo", on: "main")
        refresh([repo])
        XCTAssertEqual(GitRepoStatus.branch(repo), "main")

        try Data("ref: refs/heads/side\n".utf8)
            .write(to: repo.appendingPathComponent(".git/HEAD"))
        refresh([repo])

        XCTAssertEqual(GitRepoStatus.branch(repo), "side")
    }

    func test_branch_isNilUntilSomethingProbes() throws {
        let repo = try makeRepo("repo", on: "main")
        XCTAssertNil(GitRepoStatus.branch(repo))
    }

    func test_refreshChurn_answersEvenForDirectoriesWithNoChurn() throws {
        let repo = try makeRepo("repo", on: "main")
        let plain = try makeDir("plain", git: false)
        var landed = 0

        GitRepoStatus.refreshChurn([repo, plain]) { landed += 1 }

        waitUntil(landed == 2, "an answer for the plain directory too, not just the repo")
        XCTAssertNil(GitRepoStatus.churn(plain), "a non-repo has no counts")
    }

    func test_refreshChurn_clearsCountsWhenAProbeStopsAnswering() throws {
        let repo = root.appendingPathComponent("real-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = GitCommand.run(["init", "-q"], in: repo)
        try Data("loose\n".utf8).write(to: repo.appendingPathComponent("untracked.txt"))

        var landed = 0
        GitRepoStatus.refreshChurn([repo]) { landed += 1 }
        waitUntil(landed == 1, "the first probe to land")
        XCTAssertEqual(GitRepoStatus.churn(repo)?.untracked, 1)

        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git"))
        GitRepoStatus.refreshChurn([repo]) { landed += 1 }
        waitUntil(landed == 2, "the second probe to land")

        XCTAssertNil(GitRepoStatus.churn(repo), "the stale count must not survive")
    }

    func test_refresh_picksUpAFolderThatBecameARepo() throws {
        let dir = try makeDir("later", git: false)
        refresh([dir])
        XCTAssertEqual(GitRepoStatus.known(dir), false)

        try Data().write(to: dir.appendingPathComponent(".git"))
        refresh([dir])

        XCTAssertEqual(GitRepoStatus.known(dir), true)
    }

    func test_known_matchesRegardlessOfPathSpelling() throws {
        let repo = try makeDir("repo", git: true)
        refresh([repo])

        let unstandardized = repo.appendingPathComponent(".").appendingPathComponent("..")
            .appendingPathComponent("repo", isDirectory: true)
        XCTAssertEqual(GitRepoStatus.known(unstandardized), true)
    }

    func test_refresh_answersEachDirectoryOnItsOwn() throws {
        let repo = try makeDir("repo", git: true)
        let plain = try makeDir("plain", git: false)
        var landed = 0

        GitRepoStatus.refresh([repo, plain]) { landed += 1 }

        waitUntil(landed == 2, "an answer for each directory, not one for the batch")
        XCTAssertEqual(GitRepoStatus.known(repo), true)
        XCTAssertEqual(GitRepoStatus.known(plain), false)
    }

    func test_repoRoot_walksUpFromASubdirectory_andDeliversOnMain() throws {
        let repo = try makeDir("repo", git: true)
        let nested = repo.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        var resolved: URL??
        var onMain = false
        let landed = expectation(description: "walk landed")
        GitRepoStatus.repoRoot(for: nested) {
            resolved = $0
            onMain = Thread.isMainThread
            landed.fulfill()
        }
        wait(for: [landed], timeout: 2)

        XCTAssertEqual(resolved??.standardizedFileURL, repo.standardizedFileURL)
        XCTAssertTrue(onMain, "the completion must land on the main thread")
    }

    func test_repoRoot_nilOutsideARepo() throws {
        let plain = try makeDir("plain", git: false)

        var resolved: URL??
        let landed = expectation(description: "walk landed")
        GitRepoStatus.repoRoot(for: plain) {
            resolved = $0
            landed.fulfill()
        }
        wait(for: [landed], timeout: 2)

        XCTAssertNil(try XCTUnwrap(resolved), "a directory with no enclosing .git resolves to nil")
    }
}
