import TerminalKit
import XCTest

@testable import ZenTerm

/// What ZenTerm publishes to `theme.json` for `zen-theme.nvim` to read.
///
/// The payload is a wire contract, and every field of it is silently deniable: a reader that gets
/// `dark: true` for a light theme, or a dropped `nvimColorscheme`, applies the wrong colorscheme
/// and nothing in ZenTerm looks wrong. Property names are the JSON keys, so the encoding is
/// asserted too — a rename is a breaking change for a consumer this suite cannot see.
final class ThemePublisherTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-publisher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("themes", isDirectory: true), withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func theme(background: TerminalColor) -> AppTheme {
        let color = TerminalColor(red: 0x11, green: 0x22, blue: 0x33)
        return AppTheme(
            terminal: TerminalTheme(
                fontName: "Menlo", fontSize: 12, background: background, foreground: color,
                cursor: color, selectionBackground: color,
                ansi: (0..<16).map { TerminalColor(red: UInt8($0), green: 0, blue: 0) }))
    }

    // MARK: - the payload

    /// The token, not the resolved file, is what a reader keys off — and an absent `theme` key has
    /// to resolve to the same token the picker shows as active rather than to nil.
    func test_anAbsentThemeKey_publishesTheDefaultToken() {
        let payload = ThemePublisher.payload(for: theme(background: .init(red: 0, green: 0, blue: 0)), themeName: nil)

        XCTAssertEqual(payload.name, ThemeCatalog.defaultThemeName)
    }

    func test_aNamedTheme_publishesThatToken() {
        let payload = ThemePublisher.payload(
            for: theme(background: .init(red: 0, green: 0, blue: 0)), themeName: "nord")

        XCTAssertEqual(payload.name, "nord")
    }

    /// `dark` is read off the resolved background, so a user theme reports as accurately as a
    /// bundled one. A hardcoded `true` would pass every dark-theme assertion.
    func test_dark_followsTheResolvedBackground() {
        let dark = ThemePublisher.payload(
            for: theme(background: .init(red: 0x19, green: 0x17, blue: 0x24)), themeName: "rose-pine")
        let light = ThemePublisher.payload(
            for: theme(background: .init(red: 0xfa, green: 0xf4, blue: 0xed)), themeName: "rose-pine-dawn")

        XCTAssertTrue(dark.dark)
        XCTAssertFalse(light.dark, "a light theme has to flip `background` in the editor too")
    }

    /// Every color goes out as `#rrggbb`. Lua-side this is fed straight to a highlight group, so a
    /// bare `rrggbb` or an `0x` form is unusable.
    func test_colors_areHashPrefixedSixDigitHex() {
        let payload = ThemePublisher.payload(
            for: theme(background: .init(red: 0x2e, green: 0x34, blue: 0x40)), themeName: "nord")

        XCTAssertEqual(payload.background, "#2e3440")
        XCTAssertEqual(payload.ansi.count, 16)
        for hex in [payload.foreground, payload.cursor, payload.selectionBackground, payload.accent]
            + payload.ansi
        {
            XCTAssertEqual(
                hex.count, 7, "\(hex) is not #rrggbb")
            XCTAssertTrue(hex.hasPrefix("#"), "\(hex) is not #rrggbb")
        }
    }

    // MARK: - nvim-colorscheme

    func test_aThemeFileNamingAColorscheme_publishesIt() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("themes/my-theme")
        try "background = #101010\nnvim-colorscheme = kanagawa-dragon\n"
            .write(to: url, atomically: true, encoding: .utf8)

        let payload = ThemePublisher.resolvingColorscheme(
            ThemePublisher.payload(
                for: theme(background: .init(red: 0x10, green: 0x10, blue: 0x10)),
                themeName: "my-theme"),
            configRoot: root, themeName: "my-theme")

        XCTAssertEqual(payload.nvimColorscheme, "kanagawa-dragon")
    }

    /// Nil, not empty string: the reader's precedence chain is "override → this → leave the
    /// colorscheme alone", and an empty string would resolve as a colorscheme named "".
    func test_aThemeFileNamingNone_publishesNil() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("themes/my-theme")
        try "background = #101010\n".write(to: url, atomically: true, encoding: .utf8)

        let payload = ThemePublisher.resolvingColorscheme(
            ThemePublisher.payload(
                for: theme(background: .init(red: 0x10, green: 0x10, blue: 0x10)),
                themeName: "my-theme"),
            configRoot: root, themeName: "my-theme")

        XCTAssertNil(payload.nvimColorscheme)
    }

    func test_aKeyWithAnEmptyValue_publishesNil() throws {
        let root = try makeRoot()
        try "nvim-colorscheme =   \n".write(
            to: root.appendingPathComponent("themes/my-theme"), atomically: true, encoding: .utf8)

        XCTAssertNil(
            ThemePublisher.nvimColorscheme(inThemeAt: root.appendingPathComponent("themes/my-theme")))
    }

    func test_aCommentedKey_isIgnored() throws {
        let root = try makeRoot()
        try "# nvim-colorscheme = nope\nbackground = #101010\n".write(
            to: root.appendingPathComponent("themes/my-theme"), atomically: true, encoding: .utf8)

        XCTAssertNil(
            ThemePublisher.nvimColorscheme(inThemeAt: root.appendingPathComponent("themes/my-theme")))
    }

    /// Every bundled theme names one, so selecting any catalog entry recolors the editor. A missing
    /// one is invisible in ZenTerm: the terminal recolors and only the editor stays behind.
    func test_everyBundledTheme_namesAColorscheme() throws {
        for entry in ThemeCatalog.bundled {
            let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: entry.token), "missing \(entry.token)")
            XCTAssertNotNil(
                ThemePublisher.nvimColorscheme(inThemeAt: url), "\(entry.token) names no colorscheme")
        }
    }

    /// The key is inert to the palette parse. `GhosttyThemeParser` drops unknown keys, and if it
    /// ever stopped, every bundled theme would carry a bogus color.
    func test_theKey_doesNotDisturbTheParsedPalette() throws {
        let magenta = TerminalColor(red: 0xFF, green: 0x00, blue: 0xFF)
        let fallback = TerminalTheme(
            fontName: "Menlo", fontSize: 12, background: magenta, foreground: magenta,
            cursor: magenta, selectionBackground: magenta, ansi: Array(repeating: magenta, count: 16))

        let withKey = GhosttyThemeParser.parse(
            "background = #2e3440\nnvim-colorscheme = nord\n", fontName: "Menlo", fontSize: 12,
            fallback: fallback)
        let without = GhosttyThemeParser.parse(
            "background = #2e3440\n", fontName: "Menlo", fontSize: 12, fallback: fallback)

        XCTAssertEqual(withKey, without)
    }

    // MARK: - the write

    /// The whole path, end to end: `publish()` creates the directory and leaves a file a reader can
    /// parse. Everything above asserts the payload in memory, which stays green while the write
    /// throws and the file never appears.
    @MainActor
    func test_publish_leavesAReadableFileWhereTheReaderLooks() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("state/theme.json")
        var config = GeneralConfig.builtIn
        config.themeName = "nord"

        ThemePublisher.publish(
            theme: theme(background: .init(red: 0x2e, green: 0x34, blue: 0x40)), general: config,
            configRoot: root, to: url)
        ThemePublisher.waitForPendingWritesForTesting()

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "nord")
        XCTAssertEqual(json["background"] as? String, "#2e3440")
        XCTAssertEqual(json["nvimColorscheme"] as? String, "nord", "resolved from the bundled file")
    }

    // MARK: - the encoding

    /// The JSON keys, asserted whole. Renaming a property renames a wire field, and the only
    /// consumer lives in another repo.
    func test_theEncodedPayload_carriesTheContractsKeys() throws {
        let payload = ThemePublisher.resolvingColorscheme(
            ThemePublisher.payload(
                for: theme(background: .init(red: 0x2e, green: 0x34, blue: 0x40)),
                themeName: "nord"),
            configRoot: try makeRoot(), themeName: "nord")

        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(json.keys),
            [
                "name", "dark", "nvimColorscheme", "background", "foreground", "cursor",
                "selectionBackground", "accent", "ansi",
            ])
        XCTAssertEqual(json["nvimColorscheme"] as? String, "nord", "the bundled file's key")
    }
}
