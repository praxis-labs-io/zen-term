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
}
