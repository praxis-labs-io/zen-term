import AgentSetup
import XCTest

@testable import zen

final class CodexSetupCommandTests: XCTestCase {
    private var root: URL!
    private let files = CodexSetupFiles(skill: Data("skill".utf8), hook: Data("hook".utf8))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-setup-codex-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var environment: [String: String] { ["CODEX_HOME": root.path] }

    private func codex(_ arguments: [String] = []) throws -> SetupCommands.Codex {
        try XCTUnwrap(try Zen.parseAsRoot(["setup", "codex"] + arguments) as? SetupCommands.Codex)
    }

    func test_setupThenRerunThenRemove() throws {
        let hooks = root.appendingPathComponent("hooks.json").path
        XCTAssertEqual(
            try codex().changes(environment: environment, files: files),
            [
                "Installed the zen skill at \(root.path)/skills/zen/SKILL.md",
                "Installed the session hook at \(root.path)/hooks/zenterm-context.sh",
                "Added the SessionStart entry in \(hooks). Codex asks you to trust it when it next starts.",
            ])
        XCTAssertEqual(
            try codex().changes(environment: environment, files: files),
            ["Nothing to change: zen is set up for Codex."])
        XCTAssertEqual(try codex(["--remove"]).changes(environment: environment, files: files).count, 3)
        XCTAssertEqual(
            try codex(["--remove"]).changes(environment: environment, files: files),
            ["Nothing to remove: zen isn't set up for Codex."])
    }

    func test_aMalformedHooksFileIsAnAppError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: root.appendingPathComponent("hooks.json"))

        XCTAssertThrowsError(try codex().changes(environment: environment, files: files)) { error in
            XCTAssertEqual((error as? ZenFailure)?.exitCode, ZenFailure.appErrorCode)
        }
    }

    func test_aZenWithoutItsFilesSaysWhereToFindThem() throws {
        XCTAssertThrowsError(try codex().changes(environment: environment, files: nil)) { error in
            XCTAssertTrue((error as? ZenFailure)?.message.contains("ZenTerm.app/Contents/MacOS/zen") == true)
        }
    }
}
