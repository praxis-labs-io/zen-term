import XCTest

@testable import ZenTerm

final class DiagnosticsBundleBuilderTests: XCTestCase {
    private var dir: URL!
    private let report = SystemReport(
        appVersion: "0.3.0", build: "1234", osVersion: "15.5 (24F74)", architecture: "arm64")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeLog(_ name: String, _ contents: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_stage_writesMetadataAndCopiesLogs() throws {
        let active = try writeLog("zen-term.log", "active log\n")
        let rotated = try writeLog("zen-term.log.1", "rotated log\n")
        let staging = dir.appendingPathComponent("staged", isDirectory: true)

        try DiagnosticsBundleBuilder(report: report, logFiles: [active, rotated]).stage(into: staging)

        XCTAssertEqual(
            try String(contentsOf: staging.appendingPathComponent("metadata.txt"), encoding: .utf8),
            report.plainText)
        XCTAssertEqual(
            try String(contentsOf: staging.appendingPathComponent("zen-term.log"), encoding: .utf8),
            "active log\n")
        XCTAssertEqual(
            try String(contentsOf: staging.appendingPathComponent("zen-term.log.1"), encoding: .utf8),
            "rotated log\n")
    }

    func test_stage_skipsMissingLogsButStillWritesMetadata() throws {
        let missing = dir.appendingPathComponent("nope.log")
        let staging = dir.appendingPathComponent("staged", isDirectory: true)

        try DiagnosticsBundleBuilder(report: report, logFiles: [missing]).stage(into: staging)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staging.appendingPathComponent("metadata.txt").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging.appendingPathComponent("nope.log").path))
    }

    func test_stage_carriesOnlyMetadataAndLogs() throws {
        // The bundle must never carry the shell environment or the config file — only what it's handed.
        let active = try writeLog("zen-term.log", "x\n")
        let staging = dir.appendingPathComponent("staged", isDirectory: true)

        try DiagnosticsBundleBuilder(report: report, logFiles: [active]).stage(into: staging)

        let entries = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
        XCTAssertEqual(entries, ["metadata.txt", "zen-term.log"])
    }

    func test_build_producesZipContainingMetadataAndLogs() throws {
        let active = try writeLog("zen-term.log", "active\n")
        let destination = dir.appendingPathComponent("out.zip")

        try DiagnosticsBundleBuilder(report: report, logFiles: [active]).build(to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let magic = try FileHandle(forReadingFrom: destination).readData(ofLength: 2)
        XCTAssertEqual(magic, Data("PK".utf8), "a real zip starts with the PK signature")

        let listing = try unzipListing(destination)
        XCTAssertTrue(listing.contains("metadata.txt"), "zip carries metadata; listing was:\n\(listing)")
        XCTAssertTrue(listing.contains("zen-term.log"), "zip carries the log; listing was:\n\(listing)")
    }

    /// `unzip -l` entry names, so the test asserts the real archive rather than trusting `build`.
    private func unzipListing(_ zip: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
