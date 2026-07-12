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
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: .builtIn)
        XCTAssertEqual(app.terminal.background, Theme.rosePineMoon.background)
        XCTAssertEqual(app.chrome.destructive, TerminalColor(hex: "#eb6f92"))
    }

    func test_validThemeFileIsLoadedAndDrivesChrome() throws {
        let root = try makeTempDir()
        try "background = #010101\npalette = 1=#020202\n"
            .write(to: root.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: .builtIn)
        XCTAssertEqual(app.terminal.background, TerminalColor(hex: "#010101"))
        XCTAssertEqual(app.chrome.background, TerminalColor(hex: "#010101"))
        XCTAssertEqual(app.chrome.destructive, TerminalColor(hex: "#020202"))  // palette[1]
    }

    func test_unreadableFileFallsBackWithoutCrashing() throws {
        let root = try makeTempDir()
        // Make `theme` a directory so reading it as a file throws.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("theme"), withIntermediateDirectories: true)
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: .builtIn)
        XCTAssertEqual(app.terminal.background, Theme.rosePineMoon.background)
    }

    // MARK: - General config (ZEN-71)

    func test_loadGeneralConfig_missingFileYieldsBuiltIn() throws {
        let root = try makeTempDir()  // empty — no `config` file
        XCTAssertEqual(ConfigLoader.loadGeneralConfig(configRoot: root), .builtIn)
    }

    func test_loadGeneralConfig_parsesPresentFile() throws {
        let root = try makeTempDir()
        try "backdrop-alpha = 0.5\ncursor-style = bar\n"
            .write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let config = ConfigLoader.loadGeneralConfig(configRoot: root)
        XCTAssertEqual(config.backdropAlpha, 0.5)
        XCTAssertEqual(config.cursorStyle, .bar)
    }

    func test_loadGeneralConfig_unreadableFallsBackWithoutCrashing() throws {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        XCTAssertEqual(ConfigLoader.loadGeneralConfig(configRoot: root), .builtIn)
    }

    func test_loadAppTheme_appliesConfigFontEvenWithNoThemeFile() throws {
        let root = try makeTempDir()  // no `theme` file
        var general = GeneralConfig.builtIn
        general.fontName = "Menlo"
        general.fontSize = 18
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: general)
        XCTAssertEqual(app.terminal.fontName, "Menlo")
        XCTAssertEqual(app.terminal.fontSize, 18)
    }

    // MARK: - Workspaces (ZEN-70)

    func test_loadWorkspaces_missingFileYieldsEmpty() throws {
        let root = try makeTempDir()  // no `workspaces` file
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root), [])
    }

    func test_loadWorkspaces_parsesPresentFile() throws {
        let root = try makeTempDir()
        try "[ZenTerm]\npath = ~/Dev/zen-term\nmain = nvim\n"
            .write(to: root.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
        let workspaces = ConfigLoader.loadWorkspaces(configRoot: root)
        XCTAssertEqual(workspaces.map(\.title), ["ZenTerm"])
        XCTAssertEqual(workspaces.first?.main, "nvim")
    }

    func test_loadWorkspaces_unreadableFallsBackWithoutCrashing() throws {
        let root = try makeTempDir()
        // Make `workspaces` a directory so reading it as a file throws.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("workspaces"), withIntermediateDirectories: true)
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root), [])
    }

    // MARK: - Named theme selection (themes/<name>)

    private func writeTheme(_ name: String, background: String, in root: URL) throws {
        let dir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "background = \(background)\n"
            .write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func test_namedTheme_loadsFromThemesDir() throws {
        let root = try makeTempDir()
        try writeTheme("ocean", background: "#010203", in: root)
        var general = GeneralConfig.builtIn
        general.themeName = "ocean"
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: general)
        XCTAssertEqual(app.terminal.background, TerminalColor(hex: "#010203"))
    }

    func test_namedTheme_missing_fallsBackToBuiltInWithoutCrashing() throws {
        let root = try makeTempDir()  // no themes/ dir at all
        var general = GeneralConfig.builtIn
        general.themeName = "nope"
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: general)
        XCTAssertEqual(app.terminal.background, Theme.rosePineMoon.background)
    }

    func test_namedTheme_winsOverLegacyThemeFile() throws {
        let root = try makeTempDir()
        try "background = #999999\n"  // legacy single `theme` file
            .write(to: root.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        try writeTheme("ocean", background: "#010203", in: root)
        var general = GeneralConfig.builtIn
        general.themeName = "ocean"
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: general)
        XCTAssertEqual(app.terminal.background, TerminalColor(hex: "#010203"))  // named wins
    }
}
