import AgentSetup
import XCTest

@testable import zen

final class SetupCommandTests: XCTestCase {
    private var root: URL!
    private let files = ClaudeSetupFiles(skill: Data("skill".utf8), hook: Data("hook".utf8))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-setup-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var environment: [String: String] { ["CLAUDE_CONFIG_DIR": root.path] }

    private func claude(_ arguments: [String] = []) throws -> SetupCommands.Claude {
        try XCTUnwrap(try Zen.parseAsRoot(["setup", "claude"] + arguments) as? SetupCommands.Claude)
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

    private func pi(_ arguments: [String] = []) throws -> SetupCommands.PiAgent {
        try XCTUnwrap(try Zen.parseAsRoot(["setup", "pi"] + arguments) as? SetupCommands.PiAgent)
    }

    func test_piSetupThenRerunThenRemove() throws {
        let environment = ["PI_CODING_AGENT_DIR": root.path]
        let files = PiSetupFiles(skill: Data("skill".utf8), extension: Data("extension".utf8))

        XCTAssertEqual(try pi().changes(environment: environment, files: files).count, 2)
        XCTAssertEqual(
            try pi().changes(environment: environment, files: files), ["Nothing to change: zen is set up for Pi."])
        XCTAssertEqual(try pi(["--remove"]).changes(environment: environment, files: files).count, 2)
        XCTAssertEqual(
            try pi(["--remove"]).changes(environment: environment, files: files),
            ["Nothing to remove: zen isn't set up for Pi."])
    }
}
