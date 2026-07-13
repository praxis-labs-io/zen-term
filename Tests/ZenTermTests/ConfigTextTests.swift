import XCTest

@testable import ZenTerm

final class ConfigTextTests: XCTestCase {
    // MARK: stripComment

    func test_stripComment_wholeLine() {
        XCTAssertEqual(ConfigText.stripComment("# just a note"), "")
    }

    func test_stripComment_trailing() {
        XCTAssertEqual(ConfigText.stripComment("cursor-style = bar   # note"), "cursor-style = bar   ")
    }

    func test_stripComment_hashInsideQuotesSurvives() {
        XCTAssertEqual(
            ConfigText.stripComment("command:\"echo #1\""), "command:\"echo #1\"")
    }

    func test_stripComment_hashWithoutLeadingSpaceIsNotAComment() {
        // A `#` that neither starts the line nor follows whitespace is literal (e.g. `C#`).
        XCTAssertEqual(ConfigText.stripComment("lang = C#sharp"), "lang = C#sharp")
    }

    func test_stripComment_noComment() {
        XCTAssertEqual(ConfigText.stripComment("font-size = 14"), "font-size = 14")
    }

    // MARK: trailingComment — the inverse half of the same scan

    func test_trailingComment_returnsCommentIncludingHash() {
        XCTAssertEqual(ConfigText.trailingComment(of: "cursor-style = bar   # note"), "# note")
    }

    func test_trailingComment_nilWhenNone() {
        XCTAssertNil(ConfigText.trailingComment(of: "font-size = 14"))
    }

    func test_stripComment_and_trailingComment_partitionTheLine() {
        let line = "theme = rose-pine   # cozy"
        XCTAssertEqual(
            ConfigText.stripComment(line) + (ConfigText.trailingComment(of: line) ?? ""), line)
    }

    // MARK: unquote

    func test_unquote_stripsOnePair() {
        XCTAssertEqual(ConfigText.unquote("\"npm run dev\""), "npm run dev")
    }

    func test_unquote_leavesBareValue() {
        XCTAssertEqual(ConfigText.unquote("npm"), "npm")
    }

    func test_unquote_leavesUnbalancedQuote() {
        XCTAssertEqual(ConfigText.unquote("\"oops"), "\"oops")
    }

    func test_unquote_emptyQuotedString() {
        XCTAssertEqual(ConfigText.unquote("\"\""), "")
    }
}
