import Foundation
import XCTest

@testable import ZenTerm

final class ThemeCatalogTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
    }

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zt-catalog-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        return dir
    }

    func test_entries_startWithBuiltInDefault() throws {
        let root = try makeTempRoot()
        let entries = ThemeCatalog.entries(configRoot: root)
        XCTAssertEqual(entries.first?.source, .builtIn)
        XCTAssertNil(entries.first?.name)  // built-in = no theme key
        // With an empty user dir, the rest are bundled.
        XCTAssertTrue(entries.dropFirst().allSatisfy { $0.source == .bundled })
        XCTAssertEqual(entries.dropFirst().count, ThemeCatalog.bundled.count)
    }

    func test_userFile_shadowsBundledName_asUserSource() throws {
        let root = try makeTempRoot()
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "background = 000000\nforeground = ffffff\n".write(
            to: themes.appendingPathComponent("catppuccin-mocha"), atomically: true, encoding: .utf8)

        let entries = ThemeCatalog.entries(configRoot: root)
        let matches = entries.filter { $0.name == "catppuccin-mocha" }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.source, .user)
    }

    func test_userSubdirectory_isNotListedAsATheme() throws {
        let root = try makeTempRoot()
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "background = 000000\n".write(
            to: themes.appendingPathComponent("my-theme"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: themes.appendingPathComponent("a-folder"), withIntermediateDirectories: true)

        let entries = ThemeCatalog.entries(configRoot: root)
        XCTAssertTrue(entries.contains { $0.source == .user && $0.name == "my-theme" })
        XCTAssertFalse(entries.contains { $0.name == "a-folder" })
    }

    func test_everyBundledTheme_parsesToNonDefaultColors() throws {
        let builtIn = Theme.rosePineMoon
        for entry in ThemeCatalog.bundled {
            let url = try XCTUnwrap(
                ThemeCatalog.bundledURL(for: entry.token), "missing bundled theme \(entry.token)")
            let text = try String(contentsOf: url, encoding: .utf8)
            let theme = GhosttyThemeParser.parse(
                text, fontName: builtIn.fontName, fontSize: builtIn.fontSize, fallback: builtIn)
            // A real theme file overrides all 16 palette slots, so the ansi array won't equal the
            // fallback's. (Checking `background` alone isn't safe here: the built-in "Rosé Pine
            // Moon" default deliberately uses Rosé Pine Main's background hex, which coincides
            // with the bundled `rose-pine` [Main] file's background - see Theme.swift.)
            if entry.token != "rose-pine" {
                XCTAssertNotEqual(theme.background, builtIn.background, "\(entry.token) bg not set")
            }
            XCTAssertNotEqual(theme.ansi, builtIn.ansi, "\(entry.token) palette not set")
            XCTAssertEqual(theme.ansi.count, 16)
        }
    }
}
