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
        try Data("extension".utf8).write(to: pi.appendingPathComponent("zenterm-context.ts"))
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

    func test_readsFilesAndBuildFromAppResources() throws {
        let files = PiSetupFiles.bundled(beside: try makeApp())

        XCTAssertEqual(
            files,
            PiSetupFiles(
                skill: Data("skill".utf8), extensionScript: Data("extension".utf8),
                shippedDigests: ["aaa", "bbb"], build: 412))
    }

    func test_followsSymlinkToZen() throws {
        let zen = try makeApp()
        let link = root.appendingPathComponent("bin/zen")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zen)

        XCTAssertNotNil(PiSetupFiles.bundled(beside: link))
    }

    func test_shippedListNamesTheFilesAndCopyHasNoEmDashes() throws {
        let files = try XCTUnwrap(shipped)

        for data in [files.skill, files.extensionScript] {
            XCTAssertTrue(files.isShipped(data))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\u{2014}"))
        }
    }

    func test_installedByLaterBuildReadsAsNewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-pi-newer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = PiSetupFiles(
            skill: Data("skill v2".utf8), extensionScript: Data("extension v2".utf8), build: 412)
        _ = try PiSetup(configRoot: root, files: installed).install()

        let older = PiSetupFiles(
            skill: Data("skill v1".utf8), extensionScript: Data("extension v1".utf8), build: 411)
        XCTAssertEqual(try PiSetup(configRoot: root, files: older).state(), .newer)
    }
}
