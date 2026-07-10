import XCTest

@testable import TerminalKit

final class TerminalColorHexTests: XCTestCase {
    func test_parsesSixDigitHex() {
        let color = TerminalColor(hex: "#191724")
        XCTAssertEqual(color, TerminalColor(red: 0x19, green: 0x17, blue: 0x24))
    }

    func test_parsesThreeDigitShorthand() {
        XCTAssertEqual(TerminalColor(hex: "#abc"), TerminalColor(red: 0xaa, green: 0xbb, blue: 0xcc))
    }

    func test_isCaseInsensitiveAndTrimsWhitespace() {
        XCTAssertEqual(TerminalColor(hex: "  #E0DEF4 "), TerminalColor(red: 0xe0, green: 0xde, blue: 0xf4))
    }

    func test_acceptsBareHexWithoutLeadingHash() {
        // ghostty's config parser accepts `#`-less hex, so we must too.
        XCTAssertEqual(TerminalColor(hex: "191724"), TerminalColor(red: 0x19, green: 0x17, blue: 0x24))
        XCTAssertEqual(TerminalColor(hex: "abc"), TerminalColor(red: 0xaa, green: 0xbb, blue: 0xcc))
    }

    func test_rejectsInvalid() {
        XCTAssertNil(TerminalColor(hex: "12"))  // wrong length
        XCTAssertNil(TerminalColor(hex: "#gggggg"))  // non-hex
        XCTAssertNil(TerminalColor(hex: "white"))  // named colors unsupported
        XCTAssertNil(TerminalColor(hex: ""))
    }
}
