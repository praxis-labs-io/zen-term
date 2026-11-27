import XCTest

@testable import AgentSetup

final class CodexSetupTests: XCTestCase {
    private var root: URL!
    private let files = CodexSetupFiles(skill: Data("skill v1\n".utf8), hook: Data("hook v1\n".utf8))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-codex-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var setup: CodexSetup { CodexSetup(configRoot: root, files: files) }

    private func newer(skill: Data? = nil, hook: Data? = nil) -> CodexSetup {
        let shipped = Set([files.skill, files.hook].map(CodexSetupFiles.digest(of:)))
        return CodexSetup(
            configRoot: root,
            files: CodexSetupFiles(skill: skill ?? files.skill, hook: hook ?? files.hook, shippedDigests: shipped))
    }

    private func writeSettings(_ text: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: setup.hooksURL)
    }

    private func settings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: setup.hooksURL)) as? [String: Any])
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
            "SessionStart": [{"hooks": [{"type": "command", "command": "bash $HOME/.codex/hooks/other.sh"}]}],
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

    func test_placementsFollowTheFilesContentsOrder() {
        XCTAssertEqual(setup.placements.map(\.contents), files.contents)
    }

    func test_installKeepsEveryEntryItDidNotWrite() throws {
        try writeSettings(unrelated)

        _ = try setup.install()

        let written = try settings()
        XCTAssertEqual(written["model"] as? String, "opus")
        XCTAssertEqual((written["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertNotNil((written["hooks"] as? [String: Any])?["Stop"])
        XCTAssertEqual(try sessionStartCommands(), ["bash $HOME/.codex/hooks/other.sh", setup.hookCommand])
    }

    func test_aRerunChangesNothing() throws {
        try writeSettings(unrelated)
        _ = try setup.install()
        let written = try Data(contentsOf: setup.hooksURL)
        let modified = try FileManager.default.attributesOfItem(atPath: setup.hooksURL.path)[.modificationDate]

        XCTAssertEqual(try setup.install(), [])
        XCTAssertEqual(try Data(contentsOf: setup.hooksURL), written)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: setup.hooksURL.path)[.modificationDate] as? Date,
            modified as? Date)
    }

    func test_newBundledFilesUpdateOnlyWhatChanged() throws {
        _ = try setup.install()
        let newer = newer(skill: Data("skill v2\n".utf8))

        XCTAssertEqual(try newer.state(), .outdated)
        XCTAssertEqual(try newer.install(), ["Updated the zen skill at \(setup.skillURL.path)"])
        XCTAssertEqual(try Data(contentsOf: setup.skillURL), Data("skill v2\n".utf8))
        XCTAssertEqual(try newer.state(), .current)
    }

    func test_aNewBundledHookReadsAsOutdated() throws {
        _ = try setup.install()
        let newer = newer(hook: Data("hook v2\n".utf8))

        XCTAssertEqual(try newer.state(), .outdated)
        XCTAssertEqual(try newer.install(), ["Updated the session hook at \(setup.hookURL.path)"])
        XCTAssertEqual(try newer.state(), .current)
    }

    func test_aSkillNoBuildShippedReadsAsEdited() throws {
        _ = try setup.install()
        try Data("skill v1\nmy own rule\n".utf8).write(to: setup.skillURL)

        XCTAssertEqual(try newer(skill: Data("skill v2\n".utf8)).state(), .edited)
    }

    func test_aHookNoBuildShippedReadsAsEdited() throws {
        _ = try setup.install()
        try Data("hook v1\necho mine\n".utf8).write(to: setup.hookURL)

        XCTAssertEqual(try newer(skill: Data("skill v2\n".utf8)).state(), .edited)
    }

    func test_anEditMatchingThisBuildReadsAsCurrent() throws {
        _ = try setup.install()
        try Data("skill v2\n".utf8).write(to: setup.skillURL)

        XCTAssertEqual(try newer(skill: Data("skill v2\n".utf8)).state(), .current)
    }

    func test_aRemovedPartReadsAsEdited() throws {
        _ = try setup.install()
        try FileManager.default.removeItem(at: setup.skillURL)
        XCTAssertEqual(try newer(hook: Data("hook v2\n".utf8)).state(), .edited)

        _ = try setup.install()
        var settings = try SessionStartHooks.read(at: setup.hooksURL)
        _ = settings.unregister()
        try settings.write(to: setup.hooksURL)
        XCTAssertEqual(try newer(hook: Data("hook v2\n".utf8)).state(), .edited)
    }

    func test_anEditedSessionStartEntryReadsAsEdited() throws {
        _ = try setup.install()
        let edited = try String(contentsOf: setup.hooksURL, encoding: .utf8)
            .replacingOccurrences(of: "\"timeout\" : 5", with: "\"timeout\" : 10")
        XCTAssertTrue(edited.contains("\"timeout\" : 10"))
        try writeSettings(edited)

        XCTAssertEqual(try newer(skill: Data("skill v2\n".utf8)).state(), .edited)
        XCTAssertEqual(try setup.state(), .edited)
    }

    private func build(_ number: Int, skill: String, hook: String = "hook v1\n") -> CodexSetup {
        CodexSetup(
            configRoot: root,
            files: CodexSetupFiles(skill: Data(skill.utf8), hook: Data(hook.utf8), build: number))
    }

    func test_filesALaterBuildInstalledAreLeftAlone() throws {
        _ = try build(20, skill: "skill v2\n").install()

        XCTAssertEqual(try build(10, skill: "skill v1\n").state(), .newer)
        XCTAssertEqual(try build(20, skill: "skill v2\n").state(), .current)
        XCTAssertEqual(try build(30, skill: "skill v3\n").state(), .edited)
    }

    func test_anEditAfterALaterBuildInstalledReadsAsEdited() throws {
        _ = try build(20, skill: "skill v2\n").install()
        try Data("skill v2\nmy own rule\n".utf8).write(to: setup.skillURL)

        XCTAssertEqual(try build(10, skill: "skill v1\n").state(), .edited)
    }

    func test_anEarlierBuildInstallingAgainTakesTheStamp() throws {
        _ = try build(20, skill: "skill v2\n").install()
        _ = try build(10, skill: "skill v1\n").install()

        XCTAssertEqual(try build(10, skill: "skill v1\n").state(), .current)
        XCTAssertEqual(try build(15, skill: "skill v1.5\n").state(), .edited)
    }

    func test_installReplacesAnEditedSkill() throws {
        _ = try setup.install()
        try Data("my own skill\n".utf8).write(to: setup.skillURL)
        let newer = newer(skill: Data("skill v2\n".utf8))

        XCTAssertEqual(try newer.install(), ["Updated the zen skill at \(setup.skillURL.path)"])
        XCTAssertEqual(try newer.state(), .current)
    }

    func test_installAdoptsAnEntryWiredByHand() throws {
        try writeSettings(
            """
            {"hooks": {"SessionStart": [
              {"hooks": [{"type": "command", "command": "bash $HOME/.codex/hooks/zenterm-context.sh"}]},
              {"hooks": [{"type": "command", "command": "bash $HOME/.codex/hooks/other.sh"}]}
            ]}}
            """)

        XCTAssertEqual(try setup.state(), .edited)
        _ = try setup.install()

        XCTAssertEqual(try sessionStartCommands(), [setup.hookCommand, "bash $HOME/.codex/hooks/other.sh"])
    }

    func test_removeLeavesEveryOtherEntry() throws {
        try writeSettings(unrelated)
        _ = try setup.install()

        XCTAssertEqual(try setup.remove().count, 3)

        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.skillURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.hookURL.path))
        XCTAssertEqual(try sessionStartCommands(), ["bash $HOME/.codex/hooks/other.sh"])
        XCTAssertEqual(try settings()["model"] as? String, "opus")
        XCTAssertNotNil((try settings()["hooks"] as? [String: Any])?["Stop"])
        XCTAssertEqual(try setup.state(), .notInstalled)
        XCTAssertEqual(try setup.remove(), [])
    }

    func test_removeDeletesTheStamp() throws {
        _ = try build(20, skill: "skill v2\n").install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.stampURL.path))

        _ = try setup.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.stampURL.path))
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
            XCTAssertTrue((error as? SetupError)?.message.contains(self.setup.hooksURL.path) == true)
        }
        XCTAssertThrowsError(try setup.remove())
        XCTAssertThrowsError(try setup.state())
        XCTAssertEqual(String(decoding: try Data(contentsOf: setup.hooksURL), as: UTF8.self), broken)
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
        try FileManager.default.createSymbolicLink(at: setup.hooksURL, withDestinationURL: real)

        _ = try setup.install()

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: setup.hooksURL.path), real.path)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])?["hooks"])
    }

    func test_configRootFollowsCodexHomeThenHome() {
        XCTAssertEqual(
            CodexSetup.configRoot(environment: ["CODEX_HOME": "/tmp/c", "HOME": "/Users/me"]).path, "/tmp/c")
        XCTAssertEqual(CodexSetup.configRoot(environment: ["HOME": "/Users/me"]).path, "/Users/me/.codex")
    }

    func test_addingTheEntrySaysCodexAsksToTrustIt() throws {
        XCTAssertTrue(
            try setup.install().contains(
                "Added the SessionStart entry in \(setup.hooksURL.path). Codex asks you to trust it when it next starts."
            ))
    }

    func test_updatingOnlyTheHookScriptKeepsTheTrustedEntry() throws {
        _ = try setup.install()

        XCTAssertEqual(
            try newer(hook: Data("hook v2\n".utf8)).install(), ["Updated the session hook at \(setup.hookURL.path)"])
    }

    func test_removeKeepsAFolderHoldingFilesSetupDidNotWrite() throws {
        _ = try setup.install()
        let notes = setup.skillURL.deletingLastPathComponent().appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: notes)

        _ = try setup.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.skillURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
    }

    func test_removeDeletesTheSkillFolderItLeftEmpty() throws {
        _ = try setup.install()

        _ = try setup.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.skillURL.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("skills").path))
    }
}
