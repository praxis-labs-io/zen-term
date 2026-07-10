import XCTest

@testable import ZenTerm

final class ConfigWriterTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-config-writer-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func seed(_ text: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    private func read(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
    }

    func test_scalarSet_replacesActiveValue_preservingTrailingComment() throws {
        let dir = try makeTempDir()
        try seed("font-size = 14   # points; clamped to 6…72\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "15"], configRoot: dir)
        XCTAssertEqual(try read(dir), "font-size = 15  # points; clamped to 6…72\n")
    }

    func test_scalarSet_insertsAfterCommentedDefault() throws {
        let dir = try makeTempDir()
        try seed("# Terminal\n# font-size = 14   # points\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "18"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# Terminal\n# font-size = 14   # points\nfont-size = 18\n")
    }

    func test_scalarSet_appendsWhenAbsent() throws {
        let dir = try makeTempDir()
        try seed("# just a comment\n", in: dir)
        try ConfigWriter.apply(scalars: ["theme": "gruvbox"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# just a comment\ntheme = gruvbox\n")
    }

    func test_scalarSet_createsFileWhenAbsent() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(scalars: ["theme": "gruvbox"], configRoot: dir)
        XCTAssertEqual(try read(dir), "theme = gruvbox\n")
    }

    func test_removal_deletesActiveLine() throws {
        let dir = try makeTempDir()
        try seed("# font-size = 14\nfont-size = 20\ntheme = gruvbox\n", in: dir)
        try ConfigWriter.apply(removals: ["font-size"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# font-size = 14\ntheme = gruvbox\n")
    }

    func test_preservesUnknownKeysAndBlankLines() throws {
        let dir = try makeTempDir()
        let original = "# header\n\nunknown-key = keepme\n\ntheme = old\n"
        try seed(original, in: dir)
        try ConfigWriter.apply(scalars: ["theme": "new"], configRoot: dir)
        XCTAssertEqual(try read(dir), "# header\n\nunknown-key = keepme\n\ntheme = new\n")
    }

    func test_roundTripsThroughParser() throws {
        let dir = try makeTempDir()
        try seed("# comment\n", in: dir)
        try ConfigWriter.apply(scalars: ["font-size": "16", "backdrop-alpha": "0.5"], configRoot: dir)
        let parsed = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(parsed.fontSize, 16)
        XCTAssertEqual(parsed.backdropAlpha, 0.5)
    }

    func test_unreadableExistingFile_throwsWithoutClobbering() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config")
        let garbage = Data([0xFF, 0xFE, 0xFF])
        try garbage.write(to: url)
        XCTAssertThrowsError(try ConfigWriter.apply(scalars: ["theme": "x"], configRoot: dir))
        XCTAssertEqual(try Data(contentsOf: url), garbage)  // byte-identical: not clobbered
    }

    func test_writesThroughSymlink() throws {
        let dir = try makeTempDir()
        let target = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let realFile = target.appendingPathComponent("real-config")
        try "theme = old\n".write(to: realFile, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        try ConfigWriter.apply(scalars: ["theme": "new"], configRoot: dir)

        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)  // link intact
        XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "theme = new\n")  // wrote target
    }
}
