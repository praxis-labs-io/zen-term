import XCTest

@testable import AgentSetup

final class CodexSetupFilesTests: XCTestCase {
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
        let codex = contents.appendingPathComponent("Resources/\(CodexSetupFiles.bundleName).bundle/Codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: codex.appendingPathComponent("SKILL.md"))
        try Data("hook".utf8).write(to: codex.appendingPathComponent(CodexSetup.hookFileName))
        try Data("aaa\nbbb\n".utf8).write(to: codex.appendingPathComponent(CodexSetupFiles.shippedDigestsFileName))
        try Data(
            #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleVersion</key>"#
                .appending("<string>412</string></dict></plist>").utf8
        ).write(to: contents.appendingPathComponent("Info.plist"))
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let zen = macOS.appendingPathComponent("zen")
        FileManager.default.createFile(atPath: zen.path, contents: Data())
        return zen
    }

    private var buildFolder: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    }

    private var shipped: CodexSetupFiles? {
        CodexSetupFiles.bundled(beside: buildFolder.appendingPathComponent("zen"))
    }

    func test_readsTheFilesInTheAppsResources() throws {
        let files = CodexSetupFiles.bundled(beside: try makeApp())

        XCTAssertEqual(
            files,
            CodexSetupFiles(
                skill: Data("skill".utf8), hook: Data("hook".utf8), shippedDigests: ["aaa", "bbb"], build: 412))
    }

    func test_readsThemThroughASymlinkToZen() throws {
        let zen = try makeApp()
        let link = root.appendingPathComponent("bin/zen")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zen)

        XCTAssertNotNil(CodexSetupFiles.bundled(beside: link))
    }

    func test_nothingBesideABareBinary() {
        XCTAssertNil(CodexSetupFiles.bundled(beside: root.appendingPathComponent("zen")))
    }

    func test_aBuildFromSourceReadsTheBundleBesideIt() throws {
        let files = try XCTUnwrap(shipped)

        XCTAssertTrue(String(decoding: files.skill, as: UTF8.self).hasPrefix("---\nname: zen\n"))
        XCTAssertTrue(String(decoding: files.hook, as: UTF8.self).hasPrefix("#!/bin/bash\n"))
    }

    func test_theShippedListNamesTheSkillAndHookThisBuildShips() throws {
        let files = try XCTUnwrap(shipped)

        for (name, data) in [("SKILL.md", files.skill), (CodexSetup.hookFileName, files.hook)] {
            let digest = CodexSetupFiles.digest(of: data)
            XCTAssertTrue(
                files.isShipped(data),
                "\(name) changed. Add the line \(digest) to Sources/AgentSetup/Codex/"
                    + "\(CodexSetupFiles.shippedDigestsFileName), so the next build can replace this copy.")
        }
    }

    func test_theVersionChangesWithEitherFile() {
        let base = CodexSetupFiles(skill: Data("skill".utf8), hook: Data("hook".utf8))

        XCTAssertEqual(
            base.version, CodexSetupFiles(skill: base.skill, hook: base.hook, shippedDigests: ["x"]).version)
        XCTAssertNotEqual(base.version, CodexSetupFiles(skill: Data("skill2".utf8), hook: base.hook).version)
        XCTAssertNotEqual(base.version, CodexSetupFiles(skill: base.skill, hook: Data("hook2".utf8)).version)
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
        let pane = #"{"agent":{"name":"codex"},"name":"review","parent":31,"token":34}"#
        let (status, output) = try runShippedHook(environment: try zenPaneEnvironment(pane: 34, answering: pane))

        XCTAssertEqual(status, 0)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("This session runs in ZenTerm pane 34 (`$ZEN_PANE`), the user's terminal."))
        XCTAssertEqual(
            lines[1],
            #"You are helper `review`, started by pane 31. When done or stuck, report with "#
                + #"`zen pane send --pane 31 --enter "<result>"`, then stop. Put a question about your task to "#
                + #"pane 31 the same way, not request_user_input, then end your turn: the answer arrives as your "#
                + #"next message. A send that prints `{"queued":true}` arrives on its own once the user sends or "#
                + #"clears their text, or, in Claude Code, stops typing for 60 seconds; don't send it again."#)
        XCTAssertFalse(output.contains("zen tab rename"))
    }

    func test_shippedHookNeverAsksASessionToRenameItsTab() throws {
        let pane = #"{"agent":{"name":"codex"},"token":31}"#
        for start in ["startup", "clear", "resume", "compact"] {
            let (status, output) = try runShippedHook(
                environment: try zenPaneEnvironment(pane: 31, answering: pane), start: start)

            XCTAssertEqual(status, 0)
            XCTAssertTrue(output.hasPrefix("This session runs in ZenTerm pane 31"), start)
            XCTAssertFalse(output.contains("zen tab rename"), "a tab follows its agent's own title: \(start)")
            XCTAssertTrue(
                output.contains("- Your first action after the user's first prompt: read the zen skill."), start)
        }
    }

    func test_shippedHookHasNoHelperLineWithoutAParent() throws {
        let pane = #"{"agent":{"name":"codex"},"name":"lead","token":31,"worktree":{"parent":"/src/app"}}"#
        let (status, output) = try runShippedHook(environment: try zenPaneEnvironment(pane: 31, answering: pane))

        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.hasPrefix("This session runs in ZenTerm pane 31"))
        XCTAssertFalse(output.contains("You are helper"))
        XCTAssertTrue(output.contains("zen pane run --name"))
        XCTAssertTrue(output.contains("with no ready line, with `zen pane run --name <what it runs> -- <command>`"))
        XCTAssertTrue(output.contains("a helper you started closes without `--force`"))
    }

    func test_shippedHookStillSpeaksWhenThePaneCannotBeRead() throws {
        let (status, output) = try runShippedHook(environment: try zenPaneEnvironment(pane: 31, answering: nil))

        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.hasPrefix("This session runs in ZenTerm pane 31"))
        XCTAssertFalse(output.contains("You are helper"))
        XCTAssertFalse(output.contains("zen tab rename"))
    }

    func test_shippedHookStartsCodexHelpersAndRunsZenOutsideTheSandbox() throws {
        let pane = #"{"agent":{"name":"codex"},"token":31}"#
        let (status, output) = try runShippedHook(environment: try zenPaneEnvironment(pane: 31, answering: pane))

        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.contains(#"`zen pane run --name <name> -- codex "<exact scope>"`"#))
        XCTAssertTrue(output.contains(#"`sandbox_permissions: "require_escalated"` and `prefix_rule: ["zen"]`"#))
        for claudeOnly in ["--task", "/zen", "AskUserQuestion", "background mode", "EnterWorktree", "built-in"] {
            XCTAssertFalse(output.contains(claudeOnly), claudeOnly)
        }
    }

    func test_shippedSkillNamesCodexToolsInPlaceOfClaudes() throws {
        let skill = String(decoding: try XCTUnwrap(shipped).skill, as: UTF8.self)

        XCTAssertTrue(skill.contains(#"zen pane run --name review -- codex "Review src/auth"#))
        XCTAssertTrue(skill.contains(#"`sandbox_permissions: "require_escalated"` and `prefix_rule: ["zen"]`"#))
        for claudeOnly in [
            "--task", "AskUserQuestion", "background mode", "EnterWorktree", "built-in", "Claude already",
        ] {
            XCTAssertFalse(skill.contains(claudeOnly), claudeOnly)
        }
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

    // `start` is the SessionStart `source` Codex sends on stdin.
    private func runShippedHook(environment: [String: String], start: String = "startup") throws -> (Int32, String) {
        let files = try XCTUnwrap(shipped)
        let script = root.appendingPathComponent(CodexSetup.hookFileName)
        try files.hook.write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        let input = Pipe()
        process.standardInput = input

        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s1","source":"\#(start)"}"#.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
