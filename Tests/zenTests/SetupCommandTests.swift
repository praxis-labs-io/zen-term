import AgentSetup
import XCTest

@testable import zen

final class SetupCommandTests: XCTestCase {
    private var root: URL!
    private let files = ClaudeSetupFiles(skill: Data("skill".utf8), hook: Data("hook".utf8))
    private let piFiles = PiSetupFiles(skill: Data("skill".utf8), extensionScript: Data("extension".utf8))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-setup-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var environment: [String: String] { ["CLAUDE_CONFIG_DIR": root.path] }
    private var piEnvironment: [String: String] { ["PI_CODING_AGENT_DIR": root.path] }

    private func claude(_ arguments: [String] = []) throws -> SetupCommands.Claude {
        try XCTUnwrap(try Zen.parseAsRoot(["setup", "claude"] + arguments) as? SetupCommands.Claude)
    }

    private func pi(_ arguments: [String] = []) throws -> SetupCommands.PiCommand {
        try XCTUnwrap(try Zen.parseAsRoot(["setup", "pi"] + arguments) as? SetupCommands.PiCommand)
    }

    func test_setupThenRerunThenRemove() throws {
        XCTAssertEqual(try claude().changes(environment: environment, files: files).count, 3)
        XCTAssertEqual(
            try claude().changes(environment: environment, files: files),
            ["Nothing to change: zen is set up for Claude Code."])
        XCTAssertEqual(try claude(["--remove"]).changes(environment: environment, files: files).count, 3)
        XCTAssertEqual(
            try claude(["--remove"]).changes(environment: environment, files: files),
            ["Nothing to remove: zen isn't set up for Claude Code."])
    }

    func test_piSetupThenRerunThenRemove() throws {
        XCTAssertEqual(try pi().changes(environment: piEnvironment, files: piFiles).count, 2)
        XCTAssertEqual(
            try pi().changes(environment: piEnvironment, files: piFiles),
            ["Nothing to change: zen is set up for Pi."])
        XCTAssertEqual(try pi(["--remove"]).changes(environment: piEnvironment, files: piFiles).count, 2)
        XCTAssertEqual(
            try pi(["--remove"]).changes(environment: piEnvironment, files: piFiles),
            ["Nothing to remove: zen isn't set up for Pi."])
    }

    func test_aMalformedSettingsFileIsAnAppError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: root.appendingPathComponent("settings.json"))

        XCTAssertThrowsError(try claude().changes(environment: environment, files: files)) { error in
            XCTAssertEqual((error as? ZenFailure)?.exitCode, ZenFailure.appErrorCode)
        }
    }

    func test_aZenWithoutItsFilesSaysWhereToFindThem() throws {
        XCTAssertThrowsError(try claude().changes(environment: environment, files: nil)) { error in
            XCTAssertTrue((error as? ZenFailure)?.message.contains("ZenTerm.app/Contents/MacOS/zen") == true)
        }
    }
}
