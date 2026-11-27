import XCTest

@testable import AgentSetup

final class PiSetupTests: XCTestCase {
    private var root: URL!
    private let files = PiSetupFiles(skill: Data("skill v1\n".utf8), extension: Data("extension v1\n".utf8))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-pi-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var setup: PiSetup { PiSetup(configRoot: root, files: files) }

    private func newer(skill: Data? = nil, extension piExtension: Data? = nil) -> PiSetup {
        let shipped = Set([files.skill, files.extension].map(PiSetupFiles.digest(of:)))
        return PiSetup(
            configRoot: root,
            files: PiSetupFiles(
                skill: skill ?? files.skill, extension: piExtension ?? files.extension, shippedDigests: shipped))
    }

    private func build(_ number: Int, skill: String) -> PiSetup {
        PiSetup(
            configRoot: root,
            files: PiSetupFiles(skill: Data(skill.utf8), extension: files.extension, build: number))
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func test_installIntoAnEmptyConfigWritesTheSkillAndExtension() throws {
        let changes = try setup.install()

        XCTAssertEqual(
            changes,
            [
                "Installed the zen skill at \(setup.skillURL.path)",
                "Installed the session extension at \(setup.extensionURL.path)",
            ])
        XCTAssertEqual(try Data(contentsOf: setup.skillURL), files.skill)
        XCTAssertEqual(try Data(contentsOf: setup.extensionURL), files.extension)
        XCTAssertEqual(try setup.state(), .current)
    }

    func test_installWritesNoSettings() throws {
        _ = try setup.install()

        XCTAssertFalse(exists(root.appendingPathComponent("settings.json")))
    }

    func test_aRerunChangesNothing() throws {
        _ = try setup.install()

        XCTAssertEqual(try setup.install(), [])
    }

    func test_newBundledFilesUpdateOnlyWhatChanged() throws {
        _ = try setup.install()
        let newer = newer(skill: Data("skill v2\n".utf8))

        XCTAssertEqual(try newer.state(), .outdated)
        XCTAssertEqual(try newer.install(), ["Updated the zen skill at \(setup.skillURL.path)"])
        XCTAssertEqual(try newer.state(), .current)
    }

    func test_aNewBundledExtensionReadsAsOutdated() throws {
        _ = try setup.install()
        let newer = newer(extension: Data("extension v2\n".utf8))

        XCTAssertEqual(try newer.state(), .outdated)
        XCTAssertEqual(try newer.install(), ["Updated the session extension at \(setup.extensionURL.path)"])
        XCTAssertEqual(try newer.state(), .current)
    }

    func test_aSkillNoBuildShippedReadsAsEdited() throws {
        _ = try setup.install()
        try Data("skill v1\nmy own rule\n".utf8).write(to: setup.skillURL)

        XCTAssertEqual(try newer(skill: Data("skill v2\n".utf8)).state(), .edited)
    }

    func test_anExtensionNoBuildShippedReadsAsEdited() throws {
        _ = try setup.install()
        try Data("extension v1\n// mine\n".utf8).write(to: setup.extensionURL)

        XCTAssertEqual(try newer(skill: Data("skill v2\n".utf8)).state(), .edited)
    }

    func test_anEditMatchingThisBuildReadsAsCurrent() throws {
        _ = try setup.install()
        try Data("skill v2\n".utf8).write(to: setup.skillURL)

        XCTAssertEqual(try newer(skill: Data("skill v2\n".utf8)).state(), .current)
    }

    func test_aRemovedPartReadsAsEdited() throws {
        _ = try setup.install()
        try FileManager.default.removeItem(at: setup.extensionURL)

        XCTAssertEqual(try newer(skill: Data("skill v2\n".utf8)).state(), .edited)
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

    func test_theStampIsNotAFilePiLoads() {
        XCTAssertFalse(setup.stampURL.pathExtension == "ts" || setup.stampURL.pathExtension == "js")
    }

    func test_installReplacesAnEditedSkill() throws {
        _ = try setup.install()
        try Data("my own skill\n".utf8).write(to: setup.skillURL)
        let newer = newer(skill: Data("skill v2\n".utf8))

        XCTAssertEqual(try newer.install(), ["Updated the zen skill at \(setup.skillURL.path)"])
        XCTAssertEqual(try newer.state(), .current)
    }

    func test_removeDeletesWhatSetupWroteAndTheEmptySkillFolder() throws {
        _ = try build(20, skill: "skill v1\n").install()

        XCTAssertEqual(
            try setup.remove(),
            [
                "Removed the zen skill from \(setup.skillURL.path)",
                "Removed the session extension from \(setup.extensionURL.path)",
            ])

        XCTAssertFalse(exists(setup.skillURL.deletingLastPathComponent()))
        XCTAssertFalse(exists(setup.extensionURL))
        XCTAssertFalse(exists(setup.stampURL))
        XCTAssertEqual(try setup.state(), .notInstalled)
        XCTAssertEqual(try setup.remove(), [])
    }

    func test_removeKeepsEveryFileItDidNotWrite() throws {
        _ = try setup.install()
        let notes = setup.skillURL.deletingLastPathComponent().appendingPathComponent("notes.md")
        let other = root.appendingPathComponent("extensions/other.ts")
        try Data("mine\n".utf8).write(to: notes)
        try Data("mine\n".utf8).write(to: other)

        _ = try setup.remove()

        XCTAssertTrue(exists(notes), "a folder holding someone else's file stays")
        XCTAssertTrue(exists(other))
        XCTAssertFalse(exists(setup.skillURL))
        XCTAssertFalse(exists(setup.extensionURL))
    }

    func test_configRootFollowsPiCodingAgentDirThenHome() {
        XCTAssertEqual(
            PiSetup.configRoot(environment: ["PI_CODING_AGENT_DIR": "/tmp/p", "HOME": "/Users/me"]).path, "/tmp/p")
        XCTAssertEqual(PiSetup.configRoot(environment: ["HOME": "/Users/me"]).path, "/Users/me/.pi/agent")
    }
}
