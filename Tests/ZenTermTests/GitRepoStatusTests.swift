import XCTest

@testable import ZenTerm

/// The off-main git-status cache behind the ⌘⇧P picker's and Settings → Workspaces' badges
/// (ZEN-15). Pure logic over a real temp tree — no AppKit — so it pins the two things the badge
/// rows depend on: an unprobed directory answers "unknown" rather than "not a repo", and a refresh
/// re-answers, which is what lets a freshly `git init`ed folder pick up its badge without a
/// relaunch.
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
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeDir(_ name: String, git: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if git { try Data().write(to: dir.appendingPathComponent(".git")) }
        return dir
    }

    /// `refresh` answers one directory at a time (a dead mount must not hold up the others), so its
    /// completion runs once per directory. Counting those is what makes a RE-probe waitable: the
    /// cache already holds an answer then, so waiting on "an answer exists" would return before the
    /// fresh one landed and read the stale value.
    private func refresh(_ dirs: [URL]) {
        var landed = 0
        GitRepoStatus.refresh(dirs) { landed += 1 }
        waitUntil(landed == dirs.count, "every probe to land")
    }

    /// Unknown is not "no": a row that read nil as false would flash the wrong answer, and a row
    /// that never gets refreshed would show it forever.
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

    /// Every open refreshes, so a folder that becomes a repo between two opens answers correctly on
    /// the second — the reason the cache isn't a once-per-process answer.
    func test_refresh_picksUpAFolderThatBecameARepo() throws {
        let dir = try makeDir("later", git: false)
        refresh([dir])
        XCTAssertEqual(GitRepoStatus.known(dir), false)

        try Data().write(to: dir.appendingPathComponent(".git"))
        refresh([dir])

        XCTAssertEqual(GitRepoStatus.known(dir), true)
    }

    /// The picker asks with the URL it parsed from the config; the cache must not care whether that
    /// carries a trailing slash or a `.` component.
    func test_known_matchesRegardlessOfPathSpelling() throws {
        let repo = try makeDir("repo", git: true)
        refresh([repo])

        let unstandardized = repo.appendingPathComponent(".").appendingPathComponent("..")
            .appendingPathComponent("repo", isDirectory: true)
        XCTAssertEqual(GitRepoStatus.known(unstandardized), true)
    }

    /// One unreachable path must not hold the others' badges hostage, so each directory is probed
    /// and published on its own rather than as one batch. No test can make a real path hang, but a
    /// batched pass can only ever report once for the whole list, so the per-directory callback is
    /// the property that pins the independence.
    func test_refresh_answersEachDirectoryOnItsOwn() throws {
        let repo = try makeDir("repo", git: true)
        let plain = try makeDir("plain", git: false)
        var landed = 0

        GitRepoStatus.refresh([repo, plain]) { landed += 1 }

        waitUntil(landed == 2, "an answer for each directory, not one for the batch")
        XCTAssertEqual(GitRepoStatus.known(repo), true)
        XCTAssertEqual(GitRepoStatus.known(plain), false)
    }

    func test_repoRoot_walksUpFromASubdirectory() throws {
        let repo = try makeDir("repo", git: true)
        let nested = repo.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        var resolved: URL??
        let landed = expectation(description: "walk landed")
        GitRepoStatus.repoRoot(for: nested) {
            resolved = $0
            landed.fulfill()
        }
        wait(for: [landed], timeout: 2)

        XCTAssertEqual(resolved??.standardizedFileURL, repo.standardizedFileURL)
    }
}
