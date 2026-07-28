import GhosttyKit
import XCTest

@testable import TerminalKit

/// `GHOSTTY_ACTION_COLOR_CHANGE` → what the chrome does about it (ZEN-23).
///
/// The action is a notification, not a switch: libghostty has already written the color into
/// `terminal.colors` and its renderer draws from there, so the grid follows the program either
/// way. What this mapping decides is which of those colors the chrome repaints its own fill for
/// — the background, and nothing else.
final class GhosttyColorChangeTests: XCTestCase {
    private let theme = TerminalTheme(
        fontName: "JetBrainsMono Nerd Font Mono",
        fontSize: 14,
        background: TerminalColor(red: 0x19, green: 0x17, blue: 0x24),
        foreground: TerminalColor(red: 0xE0, green: 0xDE, blue: 0xF4),
        cursor: TerminalColor(red: 0xEA, green: 0x9A, blue: 0x97),
        selectionBackground: TerminalColor(red: 0x39, green: 0x35, blue: 0x52),
        ansi: (0..<16).map { TerminalColor(red: UInt8($0), green: UInt8($0), blue: UInt8($0)) }
    )

    private func change(
        _ kind: ghostty_action_color_kind_e, _ r: UInt8, _ g: UInt8, _ b: UInt8
    ) -> ghostty_action_color_change_s {
        ghostty_action_color_change_s(kind: kind, r: r, g: g, b: b)
    }

    func test_backgroundBecomesAnOverride() {
        let effect = GhosttySurface.effect(
            of: change(GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, 0x3B, 0x2E, 0x2E), theme: theme)
        XCTAssertEqual(
            effect, .background(TerminalColor(red: 0x3B, green: 0x2E, blue: 0x2E)))
    }

    /// The reset (OSC 111) arrives as an ordinary change carrying the color libghostty is
    /// restoring — our own theme background — with no flag to tell it apart from a program setting
    /// that same color. Matching the theme is what identifies it, and it has to map to nil rather
    /// than to a copy of today's theme color, or the surface is pinned to a snapshot no later
    /// theme change can move.
    func test_backgroundMatchingTheThemeClearsTheOverride() {
        let effect = GhosttySurface.effect(
            of: change(GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, 0x19, 0x17, 0x24), theme: theme)
        XCTAssertEqual(effect, .background(nil))
    }

    /// The terminal draws the foreground itself and no chrome surface repeats it, so there is
    /// nothing for the chrome to repaint.
    func test_foregroundIsIgnored() {
        let effect = GhosttySurface.effect(
            of: change(GHOSTTY_ACTION_COLOR_KIND_FOREGROUND, 0xFF, 0x00, 0x00), theme: theme)
        XCTAssertEqual(effect, .ignored)
    }

    func test_cursorIsIgnored() {
        let effect = GhosttySurface.effect(
            of: change(GHOSTTY_ACTION_COLOR_KIND_CURSOR, 0xFF, 0x00, 0x00), theme: theme)
        XCTAssertEqual(effect, .ignored)
    }

    /// A palette slot (OSC 4) is a non-negative `kind`, unlike the three named colors, which are
    /// -1/-2/-3. Slot 2 is picked over slot 0 because 0 is the value an uninitialized struct
    /// carries, so a mapping that ignored `kind` entirely would still pass on it.
    func test_paletteSlotIsIgnored() {
        let effect = GhosttySurface.effect(
            of: change(ghostty_action_color_kind_e(2), 0xFF, 0x00, 0x00), theme: theme)
        XCTAssertEqual(effect, .ignored)
    }

    /// A surface can take a color change before the chrome has handed it a theme (it is started
    /// with an optional one). With nothing to compare against, the program's color is an override:
    /// treating it as a reset would drop a color the terminal is already drawing.
    func test_backgroundWithNoThemeIsAnOverride() {
        let effect = GhosttySurface.effect(
            of: change(GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, 0x3B, 0x2E, 0x2E), theme: nil)
        XCTAssertEqual(
            effect, .background(TerminalColor(red: 0x3B, green: 0x2E, blue: 0x2E)))
    }
}
