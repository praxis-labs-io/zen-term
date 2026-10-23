import XCTest

@testable import ZenTerm

final class SubprocessTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = try makeTempDir()
    }

    func test_aChildPastItsTimeout_isStoppedAndReportedAsAFailure() throws {
        let pidFile = dir.appendingPathComponent("pid")
        let started = Date()

        let result = Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$ > '\(pidFile.path)'; exec /bin/sleep 5"],
            timeout: 0.3)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        guard case .failure(let error) = result else { return XCTFail("expected the run to time out") }
        XCTAssertTrue(error is Subprocess.TimedOut)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "the child is gone")
        XCTAssertEqual(errno, ESRCH)
    }

    func test_aGrandchildHoldingThePipesOpen_cannotOutlastTheTimeout() {
        let started = Date()

        let result = Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "/bin/sleep 5 &"], timeout: 0.3)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        guard case .failure(let error) = result else { return XCTFail("expected the run to time out") }
        XCTAssertTrue(error is Subprocess.TimedOut)
    }

    func test_aChildWithinItsTimeout_returnsItsOutput() throws {
        let script = "echo hi; echo err >&2; exit 3"
        let output = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], timeout: 5).get()

        XCTAssertEqual(output, Subprocess.Output(status: 3, stdout: "hi", stderr: "err"))
    }
}
