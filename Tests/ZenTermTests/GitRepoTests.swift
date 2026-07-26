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

}
