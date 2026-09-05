import XCTest

@testable import ZenTerm

/// The off-main git cache behind the ⌘P picker's branch labels and Settings → Workspaces' badges.
/// Pure logic over a real temp tree — no AppKit — so it pins the two things those
/// rows depend on: an unprobed directory answers "unknown" rather than "not a repo", and a refresh
/// re-answers, which is what lets a freshly `git init`ed folder, or a branch just switched in a
/// shell, show up without a relaunch.
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

    private func makeRepo(_ name: String, on branch: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let gitDir = dir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
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

    /// One probe answers both questions, so a row never renders a branch for a folder the same pass
    /// called a non-repo.
    func test_refresh_answersTheBranchAlongsideTheRepoAnswer() throws {
        let repo = try makeRepo("repo", on: "feature/zen-450")
        let plain = try makeDir("plain", git: false)

        refresh([repo, plain])

        XCTAssertEqual(GitRepoStatus.branch(repo), "feature/zen-450")
        XCTAssertNil(GitRepoStatus.branch(plain))
    }

    /// The picker probes per open, which is what makes a branch switched in a shell show up on the
    /// next ⌘P rather than at the next relaunch.
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

    /// `refreshChurn` answers for every directory it was given, including the ones with no answer.
    /// A caller counting completions (which is the only way to wait on a re-probe) hangs rather
    /// than fails if a failure path returns without calling back.
    func test_refreshChurn_answersEvenForDirectoriesWithNoChurn() throws {
        let repo = try makeRepo("repo", on: "main")
        let plain = try makeDir("plain", git: false)
        var landed = 0

        GitRepoStatus.refreshChurn([repo, plain]) { landed += 1 }

        waitUntil(landed == 2, "an answer for the plain directory too, not just the repo")
        XCTAssertNil(GitRepoStatus.churn(plain), "a non-repo has no counts")
    }

    /// A probe that cannot answer clears the counts rather than leaving the previous run's on the
    /// row. `git status` exits nonzero on an `index.lock` held by a concurrent git, and a stale
    /// `~3` asserts work that may already be committed.
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

    /// The walk-up, plus the delivery thread its callers depend on: `WindowController` and
    /// `ToolFloatController` both continue straight into AppKit from this completion, so delivering
    /// it off-main would touch the UI from a background queue rather than fail an assertion here.
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

        // Unwrap the OUTER optional first: it proves the completion actually delivered, so the
        // "resolved to nil" assertion can't pass just because nothing ever ran.
        XCTAssertNil(try XCTUnwrap(resolved), "a directory with no enclosing .git resolves to nil")
    }
}
