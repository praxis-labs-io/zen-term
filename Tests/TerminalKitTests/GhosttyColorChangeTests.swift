import GhosttyKit
import XCTest

@testable import TerminalKit

/// `GHOSTTY_ACTION_COLOR_CHANGE` → what the chrome does about it.
///
/// The action is a notification, not a switch: libghostty has already written the color into
/// `terminal.colors` and its renderer draws from there, so the grid follows the program either
/// way. What this mapping decides is which of those colors the chrome repaints its own fill for
/// (the background, and nothing else) and that the reported value is carried through untouched.
final class GhosttyColorChangeTests: XCTestCase {
    private func change(
        _ kind: ghostty_action_color_kind_e, _ r: UInt8, _ g: UInt8, _ b: UInt8
    ) -> ghostty_action_color_change_s {
        ghostty_action_color_change_s(kind: kind, r: r, g: g, b: b)
    }

    func test_backgroundIsCarriedThrough() {
        let effect = GhosttySurface.effect(
            of: change(GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, 0x3B, 0x2E, 0x2E))
        XCTAssertEqual(
            effect, .background(TerminalColor(red: 0x3B, green: 0x2E, blue: 0x2E)))
    }

    /// A reset (OSC 111) arrives as an ordinary change carrying the color libghostty is restoring,
    /// with no flag to tell it apart from a program setting that same color. Recognising the
    /// theme's own background and reporting "no override" is the tempting move and is wrong:
    /// `DynamicRGB.reset` is `override = default`, not `override = null`, so the grid stays pinned
    /// to that value and a chrome that dropped it would walk off a grid that never moved. The
    /// mapping stays value-blind, and a reset looks exactly like any other change.
    func test_aResetIsCarriedThroughLikeAnyOtherChange() {
        let restored = change(GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, 0x19, 0x17, 0x24)
        XCTAssertEqual(
            GhosttySurface.effect(of: restored),
            .background(TerminalColor(red: 0x19, green: 0x17, blue: 0x24)))
    }

    /// The terminal draws the foreground itself and no chrome surface repeats it, so there is
    /// nothing for the chrome to repaint.
    func test_foregroundIsIgnored() {
        let effect = GhosttySurface.effect(
            of: change(GHOSTTY_ACTION_COLOR_KIND_FOREGROUND, 0xFF, 0x00, 0x00))
        XCTAssertEqual(effect, .ignored)
    }

    func test_cursorIsIgnored() {
        let effect = GhosttySurface.effect(
            of: change(GHOSTTY_ACTION_COLOR_KIND_CURSOR, 0xFF, 0x00, 0x00))
        XCTAssertEqual(effect, .ignored)
    }

    /// A palette slot (OSC 4) is a non-negative `kind`, unlike the three named colors, which are
    /// -1/-2/-3. Slot 2 is picked over slot 0 because 0 is the value an uninitialized struct
    /// carries, so a mapping that ignored `kind` entirely would still pass on it.
    func test_paletteSlotIsIgnored() {
        let effect = GhosttySurface.effect(
            of: change(ghostty_action_color_kind_e(2), 0xFF, 0x00, 0x00))
        XCTAssertEqual(effect, .ignored)
    }
}
