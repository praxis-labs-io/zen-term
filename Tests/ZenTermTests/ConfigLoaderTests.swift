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
        let root = try makeTempDir()
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: .builtIn)
        XCTAssertEqual(app.terminal.background, Theme.rosePineZen.background)
        XCTAssertEqual(app.chrome.destructive, TerminalColor(hex: "#eb6f92"))
    }

    func test_validThemeFileIsLoadedAndDrivesChrome() throws {
        let root = try makeTempDir()
        try "background = #010101\npalette = 1=#020202\n"
            .write(to: root.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: .builtIn)
        XCTAssertEqual(app.terminal.background, TerminalColor(hex: "#010101"))
        XCTAssertEqual(app.chrome.background, TerminalColor(hex: "#010101"))
        XCTAssertEqual(app.chrome.destructive, TerminalColor(hex: "#020202"))
    }

    func test_unreadableFileFallsBackWithoutCrashing() throws {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("theme"), withIntermediateDirectories: true)
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: .builtIn)
        XCTAssertEqual(app.terminal.background, Theme.rosePineZen.background)
    }

    func test_loadGeneralConfig_missingFileYieldsBuiltIn() throws {
        let root = try makeTempDir()
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
        let root = try makeTempDir()
        var general = GeneralConfig.builtIn
        general.fontName = "Menlo"
        general.fontSize = 18
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: general)
        XCTAssertEqual(app.terminal.fontName, "Menlo")
        XCTAssertEqual(app.terminal.fontSize, 18)
    }

    func test_loadWorkspaces_missingFileYieldsEmpty() throws {
        let root = try makeTempDir()
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

    func test_loadWorkspaces_async_deliversTheParsedListOnTheMainThread() throws {
        let root = try makeTempDir()
        try "[ZenTerm]\npath = ~/Dev/zen-term\n\n[Notes]\npath = ~/notes\n"
            .write(to: root.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)

        var delivered: [Workspace]?
        var onMain = false
        ConfigLoader.loadWorkspaces(configRoot: root) {
            delivered = $0
            onMain = Thread.isMainThread
        }

        waitUntil(delivered != nil, "the load to land")
        XCTAssertEqual(delivered?.map(\.title), ["ZenTerm", "Notes"])
        XCTAssertTrue(onMain, "a caller building views off this must be handed it on the main thread")
    }

    func test_loadWorkspaces_async_doesNotCallBackBeforeReturning() throws {
        let root = try makeTempDir()
        try "[ZenTerm]\npath = ~/Dev/zen-term\n"
            .write(to: root.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)

        var landed = false
        ConfigLoader.loadWorkspaces(configRoot: root) { _ in landed = true }

        XCTAssertFalse(landed, "the load must not block the caller")
        waitUntil(landed, "the load to land")
    }

    func test_loadWorkspaces_unreadableFallsBackWithoutCrashing() throws {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("workspaces"), withIntermediateDirectories: true)
        XCTAssertEqual(ConfigLoader.loadWorkspaces(configRoot: root), [])
    }

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
        let root = try makeTempDir()
        var general = GeneralConfig.builtIn
        general.themeName = "nope"
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: general)
        XCTAssertEqual(app.terminal.background, Theme.rosePineZen.background)
    }

    func test_namedTheme_winsOverLegacyThemeFile() throws {
        let root = try makeTempDir()
        try "background = #999999\n"
            .write(to: root.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        try writeTheme("ocean", background: "#010203", in: root)
        var general = GeneralConfig.builtIn
        general.themeName = "ocean"
        let app = ConfigLoader.loadAppTheme(configRoot: root, general: general)
        XCTAssertEqual(app.terminal.background, TerminalColor(hex: "#010203"))
    }
}
