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

    func test_resolveRepoRoot_deliversRootOnMain() throws {
        let repo = try makeDir("proj", git: true)
        let nested = repo.appendingPathComponent("src/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let done = expectation(description: "resolved")
        var resolved: URL?
        var onMain = false
        GitRepo.resolveRepoRoot(for: nested) { root in
            resolved = root
            onMain = Thread.isMainThread
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        XCTAssertTrue(onMain, "the completion must land on the main thread")
        XCTAssertEqual(resolved?.standardizedFileURL, repo.standardizedFileURL)
    }

    func test_resolveRepoRoot_nilOutsideARepo() {
        let done = expectation(description: "resolved")
        var resolved: URL? = root
        GitRepo.resolveRepoRoot(for: root) { root in
            resolved = root
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertNil(resolved, "a directory with no enclosing .git resolves to nil")
    }
}
