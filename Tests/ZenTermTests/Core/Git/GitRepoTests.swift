import XCTest

@testable import ZenTerm

final class GitRepoTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        GitRepo.homeOverrideForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    func test_repoRoot_walksUpToTheEnclosingRepo() throws {
        let repo = try makeDir("mono", git: true)
        let package = try makeDir("mono/apps/rails")

        XCTAssertEqual(GitRepo.repoRoot(for: package)?.path, repo.standardizedFileURL.path)
    }

    func test_repoRoot_refusesARepoAtHomeAsAnEnclosingRepo() throws {
        GitRepo.homeOverrideForTesting = root
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        let plain = try makeDir("notes")

        XCTAssertNil(
            GitRepo.repoRoot(for: plain), "dotfiles at home must not claim every folder under it")
    }

    func test_repoRoot_stillAnswersWhenHomeItselfIsTheWorkspace() throws {
        GitRepo.homeOverrideForTesting = root
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)

        XCTAssertEqual(GitRepo.repoRoot(for: root)?.path, root.standardizedFileURL.path)
    }

    func test_repoRoot_findsARepoBelowHome() throws {
        GitRepo.homeOverrideForTesting = root
        let repo = try makeDir("Dev/thing", git: true)

        XCTAssertEqual(GitRepo.repoRoot(for: repo)?.path, repo.standardizedFileURL.path)
    }

    func test_mirrored_landsOnTheSameFolderInTheOtherCheckout() throws {
        let repo = try makeDir("mono", git: true)
        let package = try makeDir("mono/apps/rails")
        let checkout = try makeDir("wt")
        _ = try makeDir("wt/apps/rails")

        XCTAssertEqual(
            GitRepo.mirrored(package, from: repo, into: checkout)?.path,
            checkout.appendingPathComponent("apps/rails").standardizedFileURL.path)
    }

    func test_mirrored_isNilWhenTheFolderIsNotInThatCheckout() throws {
        let repo = try makeDir("mono", git: true)
        let package = try makeDir("mono/apps/rails")
        let checkout = try makeDir("wt")

        XCTAssertNil(
            GitRepo.mirrored(package, from: repo, into: checkout),
            "the base branch may not have that folder, and the root is not a stand-in for it")
    }

    func test_mirrored_isTheCheckoutForTheRepoRootItself() throws {
        let repo = try makeDir("mono", git: true)
        let checkout = try makeDir("wt")

        XCTAssertEqual(
            GitRepo.mirrored(repo, from: repo, into: checkout)?.path,
            checkout.standardizedFileURL.path)
        XCTAssertEqual(
            GitRepo.mirrored(repo, from: nil, into: checkout)?.path,
            checkout.standardizedFileURL.path)
    }

    private func makeDir(_ name: String, git: Bool = false) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        }
        return dir
    }

    func test_isGitRepo_detectsDotGit() throws {
        let repo = try makeDir("has-git", git: true)
        let plain = try makeDir("plain")
        XCTAssertTrue(GitRepo.isGitRepo(repo))
        XCTAssertFalse(GitRepo.isGitRepo(plain))
    }

    func test_isGitRepo_matchesDotGitFile() throws {
        let worktree = try makeDir("worktree")
        FileManager.default.createFile(
            atPath: worktree.appendingPathComponent(".git").path, contents: Data("gitdir: …".utf8))
        XCTAssertTrue(GitRepo.isGitRepo(worktree))
    }

    func test_isGitRepo_missingDirIsFalse() {
        XCTAssertFalse(GitRepo.isGitRepo(root.appendingPathComponent("does-not-exist", isDirectory: true)))
    }

    private func writeHead(_ contents: String, in gitDir: URL) throws {
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: gitDir.appendingPathComponent("HEAD"))
    }

    func test_currentBranch_readsHead() throws {
        let repo = try makeDir("on-main")
        try writeHead("ref: refs/heads/main\n", in: repo.appendingPathComponent(".git", isDirectory: true))
        XCTAssertEqual(GitRepo.currentBranch(repo), "main")
    }

    func test_currentBranch_keepsSlashesInsideTheBranchName() throws {
        let repo = try makeDir("slashed")
        try writeHead(
            "ref: refs/heads/feature/zen-450-branch\n",
            in: repo.appendingPathComponent(".git", isDirectory: true))
        XCTAssertEqual(GitRepo.currentBranch(repo), "feature/zen-450-branch")
    }

    func test_currentBranch_shortensADetachedHead() throws {
        let repo = try makeDir("detached")
        try writeHead(
            "9fceb02d0ae598e95dc970b74767f19372d61af8\n",
            in: repo.appendingPathComponent(".git", isDirectory: true))
        XCTAssertEqual(GitRepo.currentBranch(repo), "9fceb02")
    }

    func test_currentBranch_followsAWorktreeGitdirPointer() throws {
        let main = try makeDir("main-checkout")
        let gitDir = main.appendingPathComponent(".git/worktrees/wt", isDirectory: true)
        try writeHead("ref: refs/heads/side\n", in: gitDir)

        let worktree = try makeDir("worktree")
        FileManager.default.createFile(
            atPath: worktree.appendingPathComponent(".git").path,
            contents: Data("gitdir: \(gitDir.path)\n".utf8))

        XCTAssertEqual(GitRepo.currentBranch(worktree), "side")
    }

    func test_currentBranch_nilOutsideARepoAndWithNoHead() throws {
        let plain = try makeDir("plain")
        let headless = try makeDir("headless", git: true)
        XCTAssertNil(GitRepo.currentBranch(plain))
        XCTAssertNil(GitRepo.currentBranch(headless), "a .git with no HEAD has no branch to show")
    }
}
