import XCTest

@testable import TerminalKit
@testable import ZenTerm

final class GhosttyThemeParserTests: XCTestCase {
    private var fallback: TerminalTheme { Theme.rosePineZen }

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
        XCTAssertEqual(theme.fontName, "TestFont")
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
        XCTAssertEqual(theme.foreground, fallback.foreground)
        XCTAssertEqual(theme.ansi, fallback.ansi)
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
        XCTAssertEqual(theme.background, fallback.background)
        XCTAssertEqual(theme.ansi[2], TerminalColor(hex: "#abcdef"))
        XCTAssertEqual(theme.ansi[0], fallback.ansi[0])
    }

    func test_theConfigASurfaceIsHandedNamesAColorForSelectedText() {
        let text = GhosttyConfigWriter.configText(for: AppTheme(terminal: fallback).terminal)
        XCTAssertTrue(text.contains("selection-foreground = #e0def4"), "got: \(text)")
    }

    func test_roundTripsGhosttyConfigWriterOutput() {
        let text = GhosttyConfigWriter.configText(for: fallback)
        let theme = parse(text)
        XCTAssertEqual(theme.background, fallback.background)
        XCTAssertEqual(theme.foreground, fallback.foreground)
        XCTAssertEqual(theme.ansi, fallback.ansi)
    }
}
