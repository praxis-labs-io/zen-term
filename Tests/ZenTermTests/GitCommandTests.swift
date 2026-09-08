import XCTest

@testable import ZenTerm

final class GitCommandTests: XCTestCase {
    /// What a failed `worktree add` actually writes: one progress line, then the failure. Handing
    /// the whole stream to a person put three lines of git on a form card.
    func test_errorDescription_keepsTheFailureAndDropsThePreamble() {
        let failure = GitCommand.Failure(
            status: 128,
            stderr: """
                Preparing worktree (new branch 'test')
                fatal: cannot lock ref 'refs/heads/test': 'refs/heads/test/branch-test' exists; \
                cannot create 'refs/heads/test'
                """)

        XCTAssertEqual(
            failure.errorDescription,
            "Cannot lock ref 'refs/heads/test': 'refs/heads/test/branch-test' exists; "
                + "cannot create 'refs/heads/test'.")
    }

    /// Nothing git says is guaranteed to carry a prefix, and dropping the only line would leave
    /// the user with a status code.
    func test_errorDescription_fallsBackToTheLastLine() {
        let failure = GitCommand.Failure(status: 1, stderr: "something went sideways\n")

        XCTAssertEqual(failure.errorDescription, "something went sideways")
    }

    func test_errorDescription_namesTheStatusWhenGitSaidNothing() {
        XCTAssertEqual(
            GitCommand.Failure(status: 128, stderr: "").errorDescription, "git exited with 128.")
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_run_returnsTrimmedStdout() throws {
        let version = try GitCommand.run(["--version"], in: dir).get()

        XCTAssertTrue(version.hasPrefix("git version"))
        XCTAssertEqual(version, version.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func test_run_surfacesStatusAndStderrOnFailure() {
        let result = GitCommand.run(["rev-parse", "HEAD"], in: dir)

        guard case .failure(let error) = result, let failure = error as? GitCommand.Failure else {
            return XCTFail("expected a failure outside a repository")
        }
        XCTAssertNotEqual(failure.status, 0)
        XCTAssertFalse(failure.stderr.isEmpty)
        // Against real git, not a fixture string: the shape of what it writes is the thing being
        // relied on, and a hand-written stderr would keep passing after git changed it.
        XCTAssertTrue(failure.stderr.hasPrefix("fatal: "), "raw stderr is kept whole")
        XCTAssertEqual(
            failure.errorDescription,
            "Not a git repository (or any of the parent directories): .git.")
    }

    func test_run_readsOutputLargerThanAPipeBuffer() throws {
        let long = String(repeating: "line of output\n", count: 20_000)
        try long.write(to: dir.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        for args in [
            ["init", "--initial-branch=main"], ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test"], ["add", "."], ["commit", "-m", "big"],
        ] {
            _ = try GitCommand.run(args, in: dir).get()
        }

        // A 64K pipe fills long before git finishes, so a runner that waits before reading deadlocks.
        let blob = try GitCommand.run(["show", "HEAD:big.txt"], in: dir).get()

        XCTAssertGreaterThan(blob.count, 65_536)
    }

    /// Draining stdout to EOF and only *then* stderr hangs forever: `git add` with `core.autocrlf`
    /// warns once per file, passing the 64K stderr buffer while stdout stays open and empty.
    /// It hangs rather than fails when reinstated, so the timeout is explicit: a test that never
    /// returns reports nothing.
    func test_run_doesNotDeadlockOnACommandThatFloodsStderr() throws {
        let repo = try XCTUnwrap(dir)
        try GitCommand.run(["init", "--initial-branch=main"], in: repo).get()
        try GitCommand.run(["config", "user.email", "test@example.com"], in: repo).get()
        try GitCommand.run(["config", "user.name", "Test"], in: repo).get()
        try GitCommand.run(["config", "core.autocrlf", "true"], in: repo).get()
        for index in 0..<1500 {
            try "line one\nline two\nline three\n".write(
                to: repo.appendingPathComponent("f\(index).txt"), atomically: true, encoding: .utf8)
        }

        let finished = expectation(description: "git add returns")
        var result: Result<String, Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            result = GitCommand.run(["add", "."], in: repo)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 60)

        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("git add should succeed despite the warnings")
        }
        // And the warnings really did exceed one pipe buffer, or this proves nothing.
        let status = try GitCommand.run(["status", "--porcelain"], in: repo).get()
        XCTAssertEqual(status.split(separator: "\n").count, 1500, "every file was staged")
    }
}
