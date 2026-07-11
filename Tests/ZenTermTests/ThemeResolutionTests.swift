import Foundation
import XCTest

@testable import ZenTerm

final class ThemeResolutionTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
    }

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zt-resolve-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        return dir
    }

    private func config(themeName: String?) -> GeneralConfig {
        var c = GeneralConfig.builtIn
        c.themeName = themeName
        return c
    }

    func test_bundledName_resolvesToBundledColors() throws {
        let root = try makeTempRoot()  // no user themes/ dir
        let theme = ConfigLoader.loadAppTheme(configRoot: root, general: config(themeName: "catppuccin-mocha"))
        XCTAssertNotEqual(theme.terminal.background, Theme.rosePineMoon.background)
    }

    func test_userFile_winsOverBundled() throws {
        let root = try makeTempRoot()
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        // A user file whose colors are clearly not Catppuccin's.
        try "background = 010203\nforeground = fefefe\n".write(
            to: themes.appendingPathComponent("catppuccin-mocha"), atomically: true, encoding: .utf8)

        let theme = ConfigLoader.loadAppTheme(configRoot: root, general: config(themeName: "catppuccin-mocha"))
        XCTAssertEqual(theme.terminal.background.red, 0x01)
        XCTAssertEqual(theme.terminal.background.green, 0x02)
        XCTAssertEqual(theme.terminal.background.blue, 0x03)
    }

    func test_unknownName_fallsBackToBuiltIn() throws {
        let root = try makeTempRoot()
        let theme = ConfigLoader.loadAppTheme(configRoot: root, general: config(themeName: "does-not-exist"))
        XCTAssertEqual(theme.terminal.background, Theme.rosePineMoon.background)
    }

    func test_nilName_isBuiltIn() throws {
        let root = try makeTempRoot()
        let theme = ConfigLoader.loadAppTheme(configRoot: root, general: config(themeName: nil))
        XCTAssertEqual(theme.terminal.background, Theme.rosePineMoon.background)
    }
}
