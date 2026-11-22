import XCTest

@testable import AgentSetup

final class ClaudeSetupFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeApp() throws -> URL {
        let contents = root.appendingPathComponent("ZenTerm.app/Contents")
        let claude = contents.appendingPathComponent("Resources/\(ClaudeSetupFiles.bundleName).bundle/Claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: claude.appendingPathComponent("SKILL.md"))
        try Data("hook".utf8).write(to: claude.appendingPathComponent(ClaudeSetup.hookFileName))
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let zen = macOS.appendingPathComponent("zen")
        FileManager.default.createFile(atPath: zen.path, contents: Data())
        return zen
    }

    private var buildFolder: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    }

    private var shipped: ClaudeSetupFiles? {
        ClaudeSetupFiles.bundled(beside: buildFolder.appendingPathComponent("zen"))
    }

    func test_readsTheFilesInTheAppsResources() throws {
        let files = ClaudeSetupFiles.bundled(beside: try makeApp())

        XCTAssertEqual(files, ClaudeSetupFiles(skill: Data("skill".utf8), hook: Data("hook".utf8)))
    }

    func test_readsThemThroughASymlinkToZen() throws {
        let zen = try makeApp()
        let link = root.appendingPathComponent("bin/zen")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zen)

        XCTAssertNotNil(ClaudeSetupFiles.bundled(beside: link))
    }

    func test_nothingBesideABareBinary() {
        XCTAssertNil(ClaudeSetupFiles.bundled(beside: root.appendingPathComponent("zen")))
    }

    func test_aBuildFromSourceReadsTheBundleBesideIt() throws {
        let files = try XCTUnwrap(shipped)

        XCTAssertTrue(String(decoding: files.skill, as: UTF8.self).hasPrefix("---\nname: zen\n"))
        XCTAssertTrue(String(decoding: files.hook, as: UTF8.self).hasPrefix("#!/bin/bash\n"))
    }

    func test_shippedCopyHasNoEmDashes() throws {
        let files = try XCTUnwrap(shipped)

        for data in [files.skill, files.hook] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\u{2014}"))
        }
    }

    func test_shippedHookSaysNothingOutsideZenTerm() throws {
        let files = try XCTUnwrap(shipped)
        let script = root.appendingPathComponent(ClaudeSetup.hookFileName)
        try files.hook.write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
