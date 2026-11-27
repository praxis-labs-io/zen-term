import XCTest

@testable import AgentSetup

final class PiSetupFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-pi-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeApp() throws -> URL {
        let contents = root.appendingPathComponent("ZenTerm.app/Contents")
        let pi = contents.appendingPathComponent("Resources/\(PiSetupFiles.bundleName).bundle/Pi")
        try FileManager.default.createDirectory(at: pi, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: pi.appendingPathComponent("SKILL.md"))
        try Data("extension".utf8).write(to: pi.appendingPathComponent(PiSetup.extensionFileName))
        try Data("aaa\nbbb\n".utf8).write(to: pi.appendingPathComponent(PiSetupFiles.shippedDigestsFileName))
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

    private var shipped: PiSetupFiles? {
        PiSetupFiles.bundled(
            beside: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("zen"))
    }

    func test_readsTheFilesInTheAppsResources() throws {
        XCTAssertEqual(
            PiSetupFiles.bundled(beside: try makeApp()),
            PiSetupFiles(
                skill: Data("skill".utf8), extension: Data("extension".utf8), shippedDigests: ["aaa", "bbb"],
                build: 412))
    }

    func test_nothingBesideABareBinary() {
        XCTAssertNil(PiSetupFiles.bundled(beside: root.appendingPathComponent("zen")))
    }

    func test_aBuildFromSourceReadsTheBundleBesideIt() throws {
        let files = try XCTUnwrap(shipped)

        XCTAssertTrue(String(decoding: files.skill, as: UTF8.self).hasPrefix("---\nname: zen\n"))
        XCTAssertTrue(String(decoding: files.extension, as: UTF8.self).contains("export default function"))
    }

    func test_theShippedListNamesTheSkillAndExtensionThisBuildShips() throws {
        let files = try XCTUnwrap(shipped)

        for (name, data) in [("SKILL.md", files.skill), (PiSetup.extensionFileName, files.extension)] {
            let digest = PiSetupFiles.digest(of: data)
            XCTAssertTrue(
                files.isShipped(data),
                "\(name) changed. Add the line \(digest) to Sources/AgentSetup/Pi/"
                    + "\(PiSetupFiles.shippedDigestsFileName), so the next build can replace this copy.")
        }
    }

    func test_theVersionChangesWithEitherFile() {
        let base = PiSetupFiles(skill: Data("skill".utf8), extension: Data("extension".utf8))

        XCTAssertEqual(
            base.version, PiSetupFiles(skill: base.skill, extension: base.extension, shippedDigests: ["x"]).version)
        XCTAssertNotEqual(base.version, PiSetupFiles(skill: Data("skill2".utf8), extension: base.extension).version)
        XCTAssertNotEqual(base.version, PiSetupFiles(skill: base.skill, extension: Data("extension2".utf8)).version)
    }

    func test_shippedCopyHasNoEmDashes() throws {
        let files = try XCTUnwrap(shipped)

        for data in [files.skill, files.extension] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\u{2014}"))
        }
    }

    func test_theShippedSkillIsPisOwn() throws {
        let skill = String(decoding: try XCTUnwrap(shipped).skill, as: UTF8.self)

        XCTAssertTrue(skill.contains(#"-- pi ""#))
        for claudeOnly in ["AskUserQuestion", "EnterWorktree", "background mode.", "--task"] {
            XCTAssertFalse(skill.contains(claudeOnly), claudeOnly)
        }
    }
}
