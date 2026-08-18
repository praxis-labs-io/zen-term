import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SyntaxRoleTests: XCTestCase {
    // Rosé Pine Zen maps each role to a distinct palette hue, so a mis-wired case (keyword resolving
    // to the string color, say) would fail rather than pass by coincidence.
    private let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineZen)

    func test_eachRoleResolvesToItsChromeField() {
        XCTAssertEqual(SyntaxRole.keyword.color(chrome), chrome.synKeyword.nsColor)
        XCTAssertEqual(SyntaxRole.string.color(chrome), chrome.synString.nsColor)
        XCTAssertEqual(SyntaxRole.comment.color(chrome), chrome.synComment.nsColor)
        XCTAssertEqual(SyntaxRole.number.color(chrome), chrome.synNumber.nsColor)
        XCTAssertEqual(SyntaxRole.type.color(chrome), chrome.synType.nsColor)
        XCTAssertEqual(SyntaxRole.function.color(chrome), chrome.synFunction.nsColor)
        XCTAssertEqual(SyntaxRole.punctuation.color(chrome), chrome.synPunctuation.nsColor)
    }

    func test_rolesAreDistinctUnderThisPalette() {
        let keys = [SyntaxRole.keyword, .string, .comment, .number, .type, .function, .punctuation]
            .map { role -> String in
                guard let rgb = role.color(chrome).usingColorSpace(.sRGB) else { return "?" }
                return "\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent)"
            }
        XCTAssertEqual(Set(keys).count, keys.count, "each role should resolve to its own hue")
    }
}
