import XCTest

@testable import AppLog

final class LogTests: XCTestCase {
    private var dir: URL!
    private var savedSink: LogFileSink?
    private var savedVerbose: Bool!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedSink = Log.fileSink
        savedVerbose = Log.isVerbose
        Log.fileSink = LogFileSink(directory: dir, fileName: "zen-term.log", maxBytes: 1_000_000, maxFiles: 2)
    }

    override func tearDownWithError() throws {
        Log.fileSink = savedSink
        Log.isVerbose = savedVerbose
        try? FileManager.default.removeItem(at: dir)
    }

    private func logContents() -> String {
        Log.fileSink?.flush()
        return (try? String(contentsOf: dir.appendingPathComponent("zen-term.log"), encoding: .utf8)) ?? ""
    }

    func testWarningIsWrittenToFile() {
        Log.warning("bind failed", category: .nav)
        XCTAssertTrue(logContents().contains("WARN  [nav]  bind failed"))
    }

    func testDebugIsSuppressedFromFileWhenNotVerbose() {
        Log.isVerbose = false
        Log.debug("nav frame dump", category: .nav)
        XCTAssertFalse(logContents().contains("nav frame dump"), "debug must not reach the file off verbose")
    }

    func testDebugReachesFileWhenVerbose() {
        Log.isVerbose = true
        Log.debug("nav frame dump", category: .nav)
        XCTAssertTrue(logContents().contains("DEBUG  [nav]  nav frame dump"))
    }
}
