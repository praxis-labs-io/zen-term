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
        let (status, output) = try runShippedHook(environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.isEmpty)
    }

    func test_shippedHookNamesAHelpersParent() throws {
        let pane = #"{"agent":{"name":"claude"},"name":"review","parent":31,"token":34}"#
        let (status, output) = try runShippedHook(environment: try zenPaneEnvironment(pane: 34, answering: pane))

        XCTAssertEqual(status, 0)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("This session runs in ZenTerm pane 34 (`$ZEN_PANE`), the user's terminal."))
        XCTAssertEqual(
            lines[1],
            #"You are helper `review`, started by pane 31. When done or stuck, report with "#
                + #"`zen pane send --pane 31 --enter "<result>"`, then stop."#)
    }

    func test_shippedHookHasNoHelperLineWithoutAParent() throws {
        let pane = #"{"agent":{"name":"claude"},"name":"lead","token":31,"worktree":{"parent":"/src/app"}}"#
        let (status, output) = try runShippedHook(environment: try zenPaneEnvironment(pane: 31, answering: pane))

        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.hasPrefix("This session runs in ZenTerm pane 31"))
        XCTAssertFalse(output.contains("You are helper"))
        XCTAssertTrue(output.contains("zen pane run --name"))
    }

    func test_shippedHookStillSpeaksWhenThePaneCannotBeRead() throws {
        let (status, output) = try runShippedHook(environment: try zenPaneEnvironment(pane: 31, answering: nil))

        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.hasPrefix("This session runs in ZenTerm pane 31"))
        XCTAssertFalse(output.contains("You are helper"))
    }

    // A stub `zen` that answers `hello`, and `pane get` with `pane`, or fails it when nil.
    private func zenPaneEnvironment(pane token: Int, answering pane: String?) throws -> [String: String] {
        let bin = root.appendingPathComponent("stub-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let reply = root.appendingPathComponent("pane.json")
        try Data((pane ?? "").utf8).write(to: reply)
        let getAnswer = pane == nil ? "exit 1" : "cat '\(reply.path)'"
        let script = """
            #!/bin/bash
            case "$*" in
              *hello*) echo '{}' ;;
              *"pane get \(token)"*) \(getAnswer) ;;
              *) exit 1 ;;
            esac
            """
        let zen = bin.appendingPathComponent("zen")
        try Data(script.utf8).write(to: zen)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zen.path)
        return ["PATH": "\(bin.path):/usr/bin:/bin", "ZEN_CONTROL_SOCK": "/tmp/zen-test.sock", "ZEN_PANE": "\(token)"]
    }

    private func runShippedHook(environment: [String: String]) throws -> (Int32, String) {
        let files = try XCTUnwrap(shipped)
        let script = root.appendingPathComponent(ClaudeSetup.hookFileName)
        try files.hook.write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
