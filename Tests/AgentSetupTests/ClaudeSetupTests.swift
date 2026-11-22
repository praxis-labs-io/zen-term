import XCTest

@testable import AgentSetup

final class ClaudeSetupTests: XCTestCase {
    private var root: URL!
    private let files = ClaudeSetupFiles(skill: Data("skill v1\n".utf8), hook: Data("hook v1\n".utf8))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-claude-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var setup: ClaudeSetup { ClaudeSetup(configRoot: root, files: files) }

    private func writeSettings(_ text: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: setup.settingsURL)
    }

    private func settings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: setup.settingsURL)) as? [String: Any])
    }

    private func sessionStartCommands() throws -> [String] {
        let groups = try XCTUnwrap((settings()["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private let unrelated = """
        {
          "model": "opus",
          "permissions": {"allow": ["Bash(ls:*)"]},
          "hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/other.sh"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
          }
        }
        """

    func test_installIntoAnEmptyConfigWritesTheSkillHookAndEntry() throws {
        let changes = try setup.install()

        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(try Data(contentsOf: setup.skillURL), files.skill)
        XCTAssertEqual(try Data(contentsOf: setup.hookURL), files.hook)
        XCTAssertEqual(try sessionStartCommands(), [setup.hookCommand])
        XCTAssertEqual(try setup.state(), .current)
    }

    func test_installKeepsEveryEntryItDidNotWrite() throws {
        try writeSettings(unrelated)

        _ = try setup.install()

        let written = try settings()
        XCTAssertEqual(written["model"] as? String, "opus")
        XCTAssertEqual((written["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertNotNil((written["hooks"] as? [String: Any])?["Stop"])
        XCTAssertEqual(try sessionStartCommands(), ["bash $HOME/.claude/hooks/other.sh", setup.hookCommand])
    }

    func test_aRerunChangesNothing() throws {
        try writeSettings(unrelated)
        _ = try setup.install()
        let written = try Data(contentsOf: setup.settingsURL)
        let modified = try FileManager.default.attributesOfItem(atPath: setup.settingsURL.path)[.modificationDate]

        XCTAssertEqual(try setup.install(), [])
        XCTAssertEqual(try Data(contentsOf: setup.settingsURL), written)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: setup.settingsURL.path)[.modificationDate] as? Date,
            modified as? Date)
    }

    func test_newBundledFilesUpdateOnlyWhatChanged() throws {
        _ = try setup.install()
        let newer = ClaudeSetup(
            configRoot: root, files: ClaudeSetupFiles(skill: Data("skill v2\n".utf8), hook: files.hook))

        XCTAssertEqual(try newer.state(), .outdated)
        XCTAssertEqual(try newer.install(), ["Updated the zen skill at \(setup.skillURL.path)"])
        XCTAssertEqual(try Data(contentsOf: setup.skillURL), Data("skill v2\n".utf8))
        XCTAssertEqual(try newer.state(), .current)
    }

    func test_installAdoptsAnEntryWiredByHand() throws {
        try writeSettings(
            """
            {"hooks": {"SessionStart": [
              {"hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/zenterm-context.sh"}]},
              {"hooks": [{"type": "command", "command": "bash $HOME/.claude/hooks/other.sh"}]}
            ]}}
            """)

        XCTAssertEqual(try setup.state(), .outdated)
        _ = try setup.install()

        XCTAssertEqual(try sessionStartCommands(), [setup.hookCommand, "bash $HOME/.claude/hooks/other.sh"])
    }

    func test_removeLeavesEveryOtherEntry() throws {
        try writeSettings(unrelated)
        _ = try setup.install()

        XCTAssertEqual(try setup.remove().count, 3)

        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.skillURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.hookURL.path))
        XCTAssertEqual(try sessionStartCommands(), ["bash $HOME/.claude/hooks/other.sh"])
        XCTAssertEqual(try settings()["model"] as? String, "opus")
        XCTAssertNotNil((try settings()["hooks"] as? [String: Any])?["Stop"])
        XCTAssertEqual(try setup.state(), .notInstalled)
        XCTAssertEqual(try setup.remove(), [])
    }

    func test_removeDropsTheKeysItLeftEmpty() throws {
        try writeSettings(#"{"model": "opus"}"#)
        _ = try setup.install()

        _ = try setup.remove()

        XCTAssertNil(try settings()["hooks"])
        XCTAssertEqual(try settings()["model"] as? String, "opus")
    }

    func test_malformedSettingsRefusesAndWritesNothing() throws {
        let broken = #"{"model": "opus",,}"#
        try writeSettings(broken)

        XCTAssertThrowsError(try setup.install()) { error in
            XCTAssertTrue((error as? ClaudeSetupError)?.message.contains(self.setup.settingsURL.path) == true)
        }
        XCTAssertThrowsError(try setup.remove())
        XCTAssertThrowsError(try setup.state())
        XCTAssertEqual(String(decoding: try Data(contentsOf: setup.settingsURL), as: UTF8.self), broken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.skillURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.hookURL.path))
    }

    func test_settingsOfTheWrongShapeRefuse() throws {
        try writeSettings(#"{"hooks": {"SessionStart": "bash x.sh"}}"#)

        XCTAssertThrowsError(try setup.install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.skillURL.path))
    }

    func test_writesThroughASymlinkedSettingsFile() throws {
        let dotfiles = root.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("settings.json")
        try Data(#"{"model": "opus"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: setup.settingsURL, withDestinationURL: real)

        _ = try setup.install()

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: setup.settingsURL.path), real.path)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])?["hooks"])
    }

    func test_configRootFollowsClaudeConfigDirThenHome() {
        XCTAssertEqual(
            ClaudeSetup.configRoot(environment: ["CLAUDE_CONFIG_DIR": "/tmp/c", "HOME": "/Users/me"]).path, "/tmp/c")
        XCTAssertEqual(ClaudeSetup.configRoot(environment: ["HOME": "/Users/me"]).path, "/Users/me/.claude")
    }
}
