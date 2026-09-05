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
        try? FileManager.default.removeItem(at: root)
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
        // A worktree/submodule has `.git` as a file, not a directory — `fileExists` matches both.
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

    /// A branch name carries its own slashes, so only the `refs/heads/` prefix comes off.
    func test_currentBranch_keepsSlashesInsideTheBranchName() throws {
        let repo = try makeDir("slashed")
        try writeHead(
            "ref: refs/heads/feature/zen-450-branch\n",
            in: repo.appendingPathComponent(".git", isDirectory: true))
        XCTAssertEqual(GitRepo.currentBranch(repo), "feature/zen-450-branch")
    }

    /// A detached HEAD holds a bare sha. Showing its short form beats showing nothing: the row
    /// would otherwise look like a folder that isn't a repo at all.
    func test_currentBranch_shortensADetachedHead() throws {
        let repo = try makeDir("detached")
        try writeHead(
            "9fceb02d0ae598e95dc970b74767f19372d61af8\n",
            in: repo.appendingPathComponent(".git", isDirectory: true))
        XCTAssertEqual(GitRepo.currentBranch(repo), "9fceb02")
    }

    /// A worktree's `.git` is a file pointing at the real git dir, which holds the worktree's own
    /// HEAD — the branch the worktree is on, not the main checkout's.
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
