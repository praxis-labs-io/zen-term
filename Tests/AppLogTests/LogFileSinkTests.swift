import XCTest

@testable import AppLog

final class LogFileSinkTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("applog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func contents(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func testRotatesWhenActiveFileExceedsSizeCap() {
        let sink = LogFileSink(directory: dir, fileName: "zen-term.log", maxBytes: 64, maxFiles: 2)
        for i in 0..<10 { sink.writeLine("line number \(i)") }  // ~14 bytes each, well past 64
        sink.flush()

        XCTAssertTrue(exists("zen-term.log"), "active log should exist")
        XCTAssertTrue(exists("zen-term.log.1"), "a rotated log should exist once the cap is passed")
    }

    func testDropsOldestRotationBeyondMaxFiles() {
        let sink = LogFileSink(directory: dir, fileName: "zen-term.log", maxBytes: 40, maxFiles: 2)
        for _ in 0..<5 { sink.writeLine("AAAAAAAAAAAAAAAA") }  // first generation
        sink.flush()
        for _ in 0..<5 { sink.writeLine("BBBBBBBBBBBBBBBB") }  // second generation
        sink.flush()

        XCTAssertFalse(exists("zen-term.log.2"), "maxFiles=2 keeps only the active file and one rotation")
        let rotated = contents("zen-term.log.1") ?? ""
        XCTAssertTrue(rotated.contains("B"), "the newest rotation survives")
        XCTAssertFalse(rotated.contains("A"), "the oldest generation was dropped, not left stale in .1")
    }

    func testFileURLsListsActiveThenExistingRotations() {
        let sink = LogFileSink(directory: dir, fileName: "zen-term.log", maxBytes: 40, maxFiles: 3)
        XCTAssertEqual(sink.fileURLs, [], "nothing to list before the first write")

        for _ in 0..<3 { sink.writeLine("AAAAAAAAAAAAAAAA") }  // ~17 bytes each, forces one rotation
        sink.flush()

        let names = sink.fileURLs.map(\.lastPathComponent)
        XCTAssertEqual(names.first, "zen-term.log", "the active file leads")
        XCTAssertTrue(names.contains("zen-term.log.1"), "a rotation is listed once it exists")
        XCTAssertFalse(names.contains("zen-term.log.2"), "a rotation that doesn't exist yet isn't listed")
    }

    func testFileURLsDrainsQueuedWritesSoTheExportSeesEveryLine() throws {
        let sink = LogFileSink(directory: dir, fileName: "zen-term.log", maxBytes: 5_000_000, maxFiles: 2)
        let count = 500
        for i in 0..<count { sink.writeLine("entry-\(i)") }

        // No flush(): reading fileURLs must itself drain the write queue. Without that, the file on
        // disk still holds only a prefix of the 500 just-queued lines, and Export Diagnostics would
        // ship a truncated log missing the newest, most relevant lines.
        let active = try XCTUnwrap(sink.fileURLs.first)
        let contents = try String(contentsOf: active, encoding: .utf8)

        XCTAssertEqual(
            contents.split(separator: "\n").count, count,
            "fileURLs must drain queued writes before the export reads them")
        XCTAssertTrue(contents.contains("entry-\(count - 1)"), "the newest line must be on disk")
    }

    func testRotationLosesOrDuplicatesNoLineWithinCapacity() {
        let sink = LogFileSink(directory: dir, fileName: "zen-term.log", maxBytes: 50, maxFiles: 20)
        let lines = (0..<30).map { "entry-\($0)" }
        for line in lines { sink.writeLine(line) }
        sink.flush()

        var all: [String] = []
        if let active = contents("zen-term.log") {
            all += active.split(separator: "\n").map(String.init)
        }
        var index = 1
        while let rotated = contents("zen-term.log.\(index)") {
            all += rotated.split(separator: "\n").map(String.init)
            index += 1
        }

        XCTAssertEqual(all.count, lines.count, "no line duplicated or lost across rotations")
        XCTAssertEqual(Set(all), Set(lines), "every line survives somewhere in the kept files")
        XCTAssertTrue((contents("zen-term.log") ?? "").contains("entry-29"), "the newest line is active")
    }
}
