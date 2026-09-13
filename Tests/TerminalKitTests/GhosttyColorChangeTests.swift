import GhosttyKit
import XCTest

@testable import TerminalKit

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

    func test_aResetIsCarriedThroughLikeAnyOtherChange() {
        let restored = change(GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, 0x19, 0x17, 0x24)
        XCTAssertEqual(
            GhosttySurface.effect(of: restored),
            .background(TerminalColor(red: 0x19, green: 0x17, blue: 0x24)))
    }

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

    func test_paletteSlotIsIgnored() {
        let effect = GhosttySurface.effect(
            of: change(ghostty_action_color_kind_e(2), 0xFF, 0x00, 0x00))
        XCTAssertEqual(effect, .ignored)
    }
}
