import XCTest

@testable import AgentSetup

// Runs the shipped extension under Node, which loads TypeScript by stripping its types from 22.18 on.
final class PiExtensionTests: XCTestCase {
    private static let nodeNeeded = (major: 22, minor: 18)
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-pi-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private struct Outcome: Decodable {
        let context: String?
        let progress: [String]
    }

    private let driver = """
        import { spawnSync } from "node:child_process";
        const { default: extension } = await import(process.argv[2]);
        const handlers = {};
        const progress = [];
        const pi = {
          on: (event, handler) => (handlers[event] ??= []).push(handler),
          exec: async (command, args) => {
            const run = spawnSync(command, args, { encoding: "utf8" });
            return { code: run.status ?? 1, stdout: run.stdout ?? "", stderr: run.stderr ?? "" };
          },
          getSettings: () => JSON.parse(process.env.PI_TEST_SETTINGS ?? "{}"),
        };
        const terminal = { setProgress: (active) => progress.push(active ? "on" : "off") };
        const ctx = {
          mode: process.env.PI_TEST_MODE ?? "tui",
          ui: { setWidget: (_key, factory) => { if (typeof factory === "function") factory({ terminal }, {}); } },
        };
        extension(pi);
        const fire = async (event, payload) => { for (const handler of handlers[event] ?? []) await handler(payload, ctx); };
        await fire("session_start", { reason: "startup" });
        const start = { systemPromptOptions: { sections: {} } };
        await fire("before_agent_start", start);
        const events = JSON.parse(process.env.PI_TEST_EVENTS ?? '[["turn_start", {}], ["agent_end", {}]]');
        for (const [event, payload] of events) await fire(event, payload);
        console.log(JSON.stringify({ context: start.systemPromptOptions.sections.zenterm ?? null, progress }));
        """

    private var basePath: String { ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin" }

    private func run(_ arguments: [String], environment: [String: String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private struct NodeUnavailable: Error {}

    private func requireNode() throws {
        let needed = "Node \(Self.nodeNeeded.major).\(Self.nodeNeeded.minor) or later on PATH"
        let (status, output) = try run(["node", "--version"], environment: ["PATH": basePath])
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = version.dropFirst().split(separator: ".").compactMap { Int($0) }
        guard status == 0, parts.count >= 2 else {
            XCTFail("The Pi extension tests need \(needed), and there is none.")
            throw NodeUnavailable()
        }
        guard (parts[0], parts[1]) >= (Self.nodeNeeded.major, Self.nodeNeeded.minor) else {
            XCTFail("The Pi extension tests need \(needed), and found \(version).")
            throw NodeUnavailable()
        }
    }

    private func shippedExtension() throws -> Data {
        let beside = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("zen")
        return try XCTUnwrap(PiSetupFiles.bundled(beside: beside)).extension
    }

    private func runExtension(_ environment: [String: String]) throws -> Outcome {
        try requireNode()
        let script = root.appendingPathComponent(PiSetup.extensionFileName)
        try shippedExtension().write(to: script)
        let driverURL = root.appendingPathComponent("driver.mjs")
        try Data(driver.utf8).write(to: driverURL)
        var env = ["PATH": basePath]
        env.merge(environment) { $1 }
        let (status, output) = try run(["node", driverURL.path, script.path], environment: env)
        XCTAssertEqual(status, 0, output)
        return try JSONDecoder().decode(Outcome.self, from: Data(output.utf8))
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
        return [
            "PATH": "\(bin.path):\(basePath)", "ZEN_CONTROL_SOCK": "/tmp/zen-test.sock", "ZEN_PANE": "\(token)",
        ]
    }

    func test_saysNothingOutsideZenTerm() throws {
        let outcome = try runExtension([:])

        XCTAssertNil(outcome.context)
        XCTAssertEqual(outcome.progress, [])
    }

    func test_namesAHelpersParent() throws {
        let pane = #"{"agent":{"name":"pi"},"name":"review","parent":31,"token":34}"#
        let outcome = try runExtension(try zenPaneEnvironment(pane: 34, answering: pane))

        let lines = try XCTUnwrap(outcome.context).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines[0].hasPrefix("This session runs in ZenTerm pane 34 (`$ZEN_PANE`), the user's terminal."))
        XCTAssertEqual(
            String(lines[1]),
            #"You are helper `review`, started by pane 31. When done or stuck, report with "#
                + #"`zen pane send --pane 31 --enter "<result>"`, then stop. Put a question about your task to "#
                + #"pane 31 the same way, not in your reply to the user, then end your turn: the answer arrives "#
                + #"as your next message. A send that prints `{"queued":true}` arrives on its own once the user "#
                + #"sends or clears their text, or, in Claude Code, stops typing for 60 seconds; don't send it again."#)
    }

    func test_stripsOnlyBackticksAndLineBreaksFromAHelpersName() throws {
        let pane = #"{"name":"r`n\r\nx","parent":31,"token":34}"#
        let outcome = try runExtension(try zenPaneEnvironment(pane: 34, answering: pane))

        XCTAssertTrue(try XCTUnwrap(outcome.context).contains("You are helper `rnx`, started by pane 31."))
    }

    func test_hasNoHelperLineWithoutAParent() throws {
        let pane = #"{"agent":{"name":"pi"},"name":"lead","token":31}"#
        let context = try XCTUnwrap(try runExtension(try zenPaneEnvironment(pane: 31, answering: pane)).context)

        XCTAssertTrue(context.hasPrefix("This session runs in ZenTerm pane 31"))
        XCTAssertFalse(context.contains("You are helper"))
        XCTAssertTrue(context.contains("- Your first action after the user's first prompt: load the zen skill."))
        XCTAssertTrue(context.contains(#"`zen pane run --name <name> -- pi "<exact scope>"`"#))
        XCTAssertTrue(context.contains("a helper you started closes without `--force`"))
    }

    func test_stillSpeaksWhenThePaneCannotBeRead() throws {
        let context = try XCTUnwrap(try runExtension(try zenPaneEnvironment(pane: 31, answering: nil)).context)

        XCTAssertTrue(context.hasPrefix("This session runs in ZenTerm pane 31"))
        XCTAssertFalse(context.contains("You are helper"))
    }

    func test_reportsEachTurnInAPane() throws {
        let outcome = try runExtension(try zenPaneEnvironment(pane: 31, answering: nil))

        XCTAssertEqual(outcome.progress, ["on", "off"])
    }

    private func progress(during events: String) throws -> [String] {
        var environment = try zenPaneEnvironment(pane: 31, answering: nil)
        environment["PI_TEST_EVENTS"] = events
        return try runExtension(environment).progress
    }

    func test_reportsACompactionBetweenTurns() throws {
        let events = #"[["session_before_compact", {"willRetry": false}], ["session_compact", {"willRetry": false}]]"#

        XCTAssertEqual(try progress(during: events), ["on", "off"])
    }

    func test_reportsAFailedCompaction() throws {
        let events =
            #"[["session_before_compact", {"willRetry": false}], ["session_compact_failed", {"willRetry": false}]]"#

        XCTAssertEqual(try progress(during: events), ["on", "off"])
    }

    func test_keepsTheTurnWorkingThroughACompactionInsideIt() throws {
        let events = """
            [["turn_start", {}], ["session_before_compact", {"willRetry": false}],
             ["session_compact", {"willRetry": false}], ["agent_end", {}]]
            """

        XCTAssertEqual(try progress(during: events), ["on", "on", "on", "off"])
    }

    func test_staysWorkingFromACompactionIntoTheTurnItRetries() throws {
        let events = """
            [["turn_start", {}], ["agent_end", {}], ["session_before_compact", {"willRetry": true}],
             ["session_compact", {"willRetry": true}], ["turn_start", {}], ["agent_end", {}]]
            """

        XCTAssertEqual(try progress(during: events), ["on", "off", "on", "on", "on", "off"])
    }

    func test_leavesTurnsToPiWhenItReportsThemItself() throws {
        var environment = try zenPaneEnvironment(pane: 31, answering: nil)
        environment["PI_TEST_SETTINGS"] = #"{"terminal":{"showTerminalProgress":true}}"#

        XCTAssertEqual(try runExtension(environment).progress, [])
    }

    func test_reportsNoTurnsOutsideTheTerminalUI() throws {
        var environment = try zenPaneEnvironment(pane: 31, answering: nil)
        environment["PI_TEST_MODE"] = "print"

        XCTAssertEqual(try runExtension(environment).progress, [])
    }
}
