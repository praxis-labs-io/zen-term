import TerminalKit
import XCTest

@testable import ZenTerm

final class LayoutFormatTerminalTokenTests: XCTestCase {
    func test_cursorStyleToken_roundTrips() {
        for style in [TerminalBehavior.CursorStyle.block, .bar, .underline] {
            let token = LayoutFormat.cursorStyleToken(style)
            XCTAssertEqual(LayoutFormat.parseCursorStyle(token), style)
        }
    }

    func test_cursorStyleTokens_areGhosttyLiterals() {
        XCTAssertEqual(LayoutFormat.cursorStyleToken(.block), "block")
        XCTAssertEqual(LayoutFormat.cursorStyleToken(.bar), "bar")
        XCTAssertEqual(LayoutFormat.cursorStyleToken(.underline), "underline")
    }

    func test_parseCursorStyle_isCaseInsensitive_andRejectsGarbage() {
        XCTAssertEqual(LayoutFormat.parseCursorStyle("  BLOCK "), .block)
        XCTAssertNil(LayoutFormat.parseCursorStyle("beam"))
    }

    func test_boolToken() {
        XCTAssertEqual(LayoutFormat.boolToken(true), "true")
        XCTAssertEqual(LayoutFormat.boolToken(false), "false")
    }
}
