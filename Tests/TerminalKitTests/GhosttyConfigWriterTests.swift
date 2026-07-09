import XCTest

@testable import TerminalKit

final class GhosttyConfigWriterTests: XCTestCase {
    private let theme = TerminalTheme(
        fontName: "JetBrainsMono Nerd Font Mono",
        fontSize: 14,
        background: TerminalColor(red: 0x19, green: 0x17, blue: 0x24),
        foreground: TerminalColor(red: 0xE0, green: 0xDE, blue: 0xF4),
        cursor: TerminalColor(red: 0xEA, green: 0x9A, blue: 0x97),
        selectionBackground: TerminalColor(red: 0x39, green: 0x35, blue: 0x52),
        ansi: (0..<16).map { TerminalColor(red: UInt8($0), green: UInt8($0), blue: UInt8($0)) }
    )

    func test_themeColorsAndFontEmitted() {
        let text = GhosttyConfigWriter.configText(for: theme)
        XCTAssertTrue(text.contains("font-family = JetBrainsMono Nerd Font Mono\n"))
        XCTAssertTrue(text.contains("font-size = 14.0\n"))
        XCTAssertTrue(text.contains("background = #191724\n"))
        XCTAssertTrue(text.contains("foreground = #e0def4\n"))
        XCTAssertTrue(text.contains("cursor-color = #ea9a97\n"))
        XCTAssertTrue(text.contains("selection-background = #393552\n"))
    }

    func test_all16PaletteEntriesEmitted() {
        let text = GhosttyConfigWriter.configText(for: theme)
        for index in 0..<16 {
            let hex = String(format: "#%02x%02x%02x", index, index, index)
            XCTAssertTrue(text.contains("palette = \(index)=\(hex)\n"), "missing palette \(index)")
        }
    }

    func test_nilThemeStillEmitsBehaviorBaseline() {
        let text = GhosttyConfigWriter.configText(for: nil)
        XCTAssertTrue(text.contains("cursor-style = block\n"))
        // Without this, shell integration swaps the block for a bar at the prompt.
        XCTAssertTrue(text.contains("shell-integration-features = no-cursor\n"))
        XCTAssertTrue(text.contains("mouse-hide-while-typing = true\n"))
        XCTAssertFalse(text.contains("font-family"))
        XCTAssertFalse(text.contains("palette"))
    }

    func test_writeConfigProducesLoadableFile() throws {
        let path = try XCTUnwrap(GhosttyConfigWriter.writeConfig(for: theme))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, GhosttyConfigWriter.configText(for: theme))
    }
}
