import XCTest

@testable import zen

final class BundleVersionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zt-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeApp(version: String) throws -> URL {
        let contents = root.appendingPathComponent("ZenTerm.app/Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info = ["CFBundleShortVersionString": version] as NSDictionary
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let zen = macOS.appendingPathComponent("zen")
        FileManager.default.createFile(atPath: zen.path, contents: Data())
        return zen
    }

    func test_readsTheVersionOfTheAppItSitsIn() throws {
        XCTAssertEqual(BundleVersion.of(executable: try makeApp(version: "1.7.0")), "1.7.0")
    }

    func test_readsThroughASymlinkToIt() throws {
        let zen = try makeApp(version: "1.7.0")
        let link = root.appendingPathComponent("bin/zen")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zen)

        XCTAssertEqual(BundleVersion.of(executable: link), "1.7.0")
    }

    func test_outsideAnAppItIsABuildFromSource() {
        XCTAssertEqual(BundleVersion.of(executable: root.appendingPathComponent("debug/zen")), "0.0.0+src")
    }
}
