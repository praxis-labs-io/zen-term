import XCTest

@testable import TerminalKit
@testable import ZenTerm

final class GhosttyThemeParserTests: XCTestCase {
    private var fallback: TerminalTheme { Theme.rosePineDarker }

    private func parse(_ text: String) -> TerminalTheme {
        GhosttyThemeParser.parse(text, fontName: "TestFont", fontSize: 12, fallback: fallback)
    }

    func test_parsesColorsAndPaletteKeepingInjectedFont() {
        let theme = parse(
            """
            # a ghostty theme
            background = #000000
            foreground = #ffffff
            cursor-color = #ff0000
            selection-background = #00ff00
            selection-foreground = #0000ff
            palette = 0=#111111
            palette = 15=#eeeeee
            """)
        XCTAssertEqual(theme.fontName, "TestFont")  // font injected, not from file
        XCTAssertEqual(theme.background, TerminalColor(hex: "#000000"))
        XCTAssertEqual(theme.foreground, TerminalColor(hex: "#ffffff"))
        XCTAssertEqual(theme.cursor, TerminalColor(hex: "#ff0000"))
        XCTAssertEqual(theme.selectionBackground, TerminalColor(hex: "#00ff00"))
        XCTAssertEqual(theme.selectionForeground, TerminalColor(hex: "#0000ff"))
        XCTAssertEqual(theme.ansi[0], TerminalColor(hex: "#111111"))
        XCTAssertEqual(theme.ansi[15], TerminalColor(hex: "#eeeeee"))
    }

    func test_missingKeysFallBack() {
        let theme = parse("background = #010203")
        XCTAssertEqual(theme.background, TerminalColor(hex: "#010203"))
        XCTAssertEqual(theme.foreground, fallback.foreground)  // untouched → fallback
        XCTAssertEqual(theme.ansi, fallback.ansi)  // no palette lines → fallback
    }

    func test_malformedLinesAndUnknownKeysIgnored() {
        let theme = parse(
            """
            font-family = Menlo
            window-padding = 4
            background = not-a-color
            palette = 99=#ffffff
            palette = 2=#abcdef
            """)
        XCTAssertEqual(theme.background, fallback.background)  // bad value → fallback
        XCTAssertEqual(theme.ansi[2], TerminalColor(hex: "#abcdef"))  // valid palette line applied
        XCTAssertEqual(theme.ansi[0], fallback.ansi[0])  // out-of-range 99 ignored
    }

    func test_theConfigASurfaceIsHandedNamesAColorForSelectedText() {
        // Silent when it is missing: libghostty leaves every cell its own color, which looks
        // correct until the text you select happens to be dark.
        let text = GhosttyConfigWriter.configText(for: AppTheme(terminal: fallback).terminal)
        XCTAssertTrue(text.contains("selection-foreground = #e0def4"), "got: \(text)")
    }

    func test_roundTripsGhosttyConfigWriterOutput() {
        // Symmetry: what GhosttyConfigWriter writes, this parses back to the same colors.
        let text = GhosttyConfigWriter.configText(for: fallback)
        let theme = parse(text)
        XCTAssertEqual(theme.background, fallback.background)
        XCTAssertEqual(theme.foreground, fallback.foreground)
        XCTAssertEqual(theme.ansi, fallback.ansi)
    }
}
