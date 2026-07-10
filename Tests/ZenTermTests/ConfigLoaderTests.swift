import TerminalKit
import XCTest

@testable import ZenTerm

final class ConfigLoaderTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func test_missingFileYieldsBuiltInDefault() throws {
        let root = try makeTempDir()  // empty — no `theme` file
        let app = ConfigLoader.loadAppTheme(configRoot: root)
        XCTAssertEqual(app.terminal.background, Theme.rosePineMoon.background)
        XCTAssertEqual(app.chrome.destructive, TerminalColor(hex: "#eb6f92"))
    }

    func test_validThemeFileIsLoadedAndDrivesChrome() throws {
        let root = try makeTempDir()
        try "background = #010101\npalette = 1=#020202\n"
            .write(to: root.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        let app = ConfigLoader.loadAppTheme(configRoot: root)
        XCTAssertEqual(app.terminal.background, TerminalColor(hex: "#010101"))
        XCTAssertEqual(app.chrome.background, TerminalColor(hex: "#010101"))
        XCTAssertEqual(app.chrome.destructive, TerminalColor(hex: "#020202"))  // palette[1]
    }

    func test_unreadableFileFallsBackWithoutCrashing() throws {
        let root = try makeTempDir()
        // Make `theme` a directory so reading it as a file throws.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("theme"), withIntermediateDirectories: true)
        let app = ConfigLoader.loadAppTheme(configRoot: root)
        XCTAssertEqual(app.terminal.background, Theme.rosePineMoon.background)
    }
}
