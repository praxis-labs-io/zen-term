import XCTest

@testable import AgentSetup

final class PiSetupTests: XCTestCase {
    private var root: URL!
    private let files = PiSetupFiles(skill: Data("skill v1\n".utf8), extensionScript: Data("extension v1\n".utf8))

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-pi-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var setup: PiSetup { PiSetup(configRoot: root, files: files) }

    private func newer(skill: Data? = nil, extensionScript: Data? = nil) -> PiSetup {
        let shipped = Set([files.skill, files.extensionScript].map(PiSetupFiles.digest(of:)))
        return PiSetup(
            configRoot: root,
            files: PiSetupFiles(
                skill: skill ?? files.skill, extensionScript: extensionScript ?? files.extensionScript,
                shippedDigests: shipped))
    }

    func test_installThenRerunAndRemove() throws {
        XCTAssertEqual(try setup.install().count, 2)
        XCTAssertEqual(try setup.state(), .current)
        XCTAssertEqual(try setup.install(), [])
        XCTAssertEqual(try setup.remove().count, 2)
        XCTAssertEqual(try setup.state(), .notInstalled)
    }

    func test_missingPartIsEdited() throws {
        _ = try setup.install()
        try FileManager.default.removeItem(at: setup.skillURL)
        XCTAssertEqual(try newer(extensionScript: Data("extension v2\n".utf8)).state(), .edited)
    }

    func test_shippedChangesAreOutdatedAndUpdate() throws {
        _ = try setup.install()
        let updated = newer(extensionScript: Data("extension v2\n".utf8))
        XCTAssertEqual(try updated.state(), .outdated)
        _ = try updated.install()
        XCTAssertEqual(try updated.state(), .current)
    }

    func test_unshippedChangesAreEdited() throws {
        _ = try setup.install()
        try Data("mine\n".utf8).write(to: setup.extensionURL)
        XCTAssertEqual(try newer(extensionScript: Data("extension v2\n".utf8)).state(), .edited)
    }

    func test_configRootUsesPiEnvironmentOrHome() {
        XCTAssertEqual(
            PiSetup.configRoot(environment: ["PI_CODING_AGENT_DIR": "~/custom-pi"]).path,
            ("~/custom-pi" as NSString).expandingTildeInPath)
        XCTAssertEqual(
            PiSetup.configRoot(environment: ["HOME": "/tmp/home"]).path,
            "/tmp/home/.pi/agent")
    }
}
