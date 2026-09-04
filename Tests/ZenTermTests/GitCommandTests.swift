import XCTest

@testable import ZenTerm

final class GitCommandTests: XCTestCase {
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
        XCTAssertEqual(failure.errorDescription, failure.stderr)
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

    /// The deadlock this guards: draining stdout to EOF and only *then* stderr hangs forever when
    /// the child fills the 64K stderr buffer first, because it blocks on write while this thread
    /// blocks on read. `git add` with `core.autocrlf` warns once per file, which passes 64K at a
    /// few hundred files while stdout stays open and empty.
    ///
    /// It hangs rather than fails when reinstated, so it is written with an explicit timeout: a
    /// test that never returns reports nothing.
    func test_run_doesNotDeadlockOnACommandThatFloodsStderr() throws {
        let repo = dir!
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
