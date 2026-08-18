import Foundation
import TerminalKit
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

    func test_entries_areTheBundledCatalog_whenTheUserDirIsEmpty() throws {
        let root = try makeTempRoot()
        let entries = ThemeCatalog.entries(configRoot: root)
        XCTAssertEqual(entries.map(\.name), ThemeCatalog.bundled.map(\.token))
        XCTAssertTrue(entries.allSatisfy { $0.source == .bundled })
        // The default is a real token now, so an unset `theme` key has something to select.
        XCTAssertEqual(entries.first?.name, ThemeCatalog.defaultThemeName)
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

    /// A fallback no real theme could coincide with, so "equals the fallback" means "not parsed".
    /// Comparing against the built-in instead would let a file that shares its hexes pass empty.
    private var sentinelFallback: TerminalTheme {
        let magenta = TerminalColor(red: 0xFF, green: 0x00, blue: 0xFF)
        return TerminalTheme(
            fontName: "Menlo", fontSize: 12, background: magenta, foreground: magenta,
            cursor: magenta, selectionBackground: magenta, ansi: Array(repeating: magenta, count: 16))
    }

    private func parseBundled(_ token: String) throws -> TerminalTheme {
        let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: token), "missing bundled theme \(token)")
        let fallback = sentinelFallback
        return GhosttyThemeParser.parse(
            try String(contentsOf: url, encoding: .utf8),
            fontName: fallback.fontName, fontSize: fallback.fontSize, fallback: fallback)
    }

    func test_everyBundledTheme_setsEveryColorItShips() throws {
        let sentinel = sentinelFallback
        for entry in ThemeCatalog.bundled {
            let theme = try parseBundled(entry.token)
            XCTAssertNotEqual(theme.background, sentinel.background, "\(entry.token) bg not set")
            XCTAssertNotEqual(theme.foreground, sentinel.foreground, "\(entry.token) fg not set")
            XCTAssertNotEqual(theme.cursor, sentinel.cursor, "\(entry.token) cursor not set")
            XCTAssertNotEqual(
                theme.selectionBackground, sentinel.selectionBackground, "\(entry.token) selection not set")
            XCTAssertNotEqual(theme.ansi, sentinel.ansi, "\(entry.token) palette not set")
            XCTAssertEqual(theme.ansi.count, 16)
        }
    }

    /// The compiled-in fallback is what an unset `theme` key resolves to, and the bundled file is
    /// what the picker writes. They are the same theme, so a hex edit to one has to reach the other.
    func test_bundledDefault_matchesTheCompiledInFallback() throws {
        let theme = try parseBundled(ThemeCatalog.defaultThemeName)
        let expected = Theme.rosePineDarker
        XCTAssertEqual(theme.background, expected.background)
        XCTAssertEqual(theme.foreground, expected.foreground)
        XCTAssertEqual(theme.cursor, expected.cursor)
        XCTAssertEqual(theme.selectionBackground, expected.selectionBackground)
        XCTAssertEqual(theme.ansi, expected.ansi)
    }

    /// The three Rosé Pines are distinct upstream themes, and shipping Moon's palette under Main's
    /// name is the bug this catalog once had.
    func test_theRosePines_carryTheirOwnUpstreamValues() throws {
        let main = try parseBundled("rose-pine")
        let moon = try parseBundled("rose-pine-moon")
        let darker = try parseBundled(ThemeCatalog.defaultThemeName)

        XCTAssertEqual(main.background, TerminalColor(red: 0x19, green: 0x17, blue: 0x24))
        XCTAssertEqual(main.ansi[2], TerminalColor(red: 0x31, green: 0x74, blue: 0x8F))  // Main's pine
        XCTAssertEqual(moon.background, TerminalColor(red: 0x23, green: 0x21, blue: 0x36))
        XCTAssertEqual(moon.ansi[2], TerminalColor(red: 0x3E, green: 0x8F, blue: 0xB0))  // Moon's pine
        XCTAssertEqual(darker.background, main.background)
        XCTAssertEqual(darker.ansi, moon.ansi)
    }
}
