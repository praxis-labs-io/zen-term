import XCTest

@testable import ZenTerm

final class DiffHighlighterTests: XCTestCase {
    // MARK: - Pure range→line mapping (no grammar)

    func test_perLineSpans_mapsSingleLineCaptureRelativeToItsLine() {
        // "ab\ncde\nfg": line 1 = [0,2), line 2 = [3,3), line 3 = [7,2).
        let text = "ab\ncde\nfg"
        let spans = DiffHighlighter.perLineSpans(
            text: text, captures: [(NSRange(location: 0, length: 2), .keyword)])
        XCTAssertEqual(spans, [1: [TokenSpan(range: NSRange(location: 0, length: 2), role: .keyword)]])
    }

    func test_perLineSpans_splitsAMultilineCaptureAcrossLinesClampedToEach() {
        // A capture [4,4) covers "e" on line 2 (offset 4-5) and "f" on line 3 (offset 7), across the
        // newline — each line gets its own line-relative, clamped span.
        let text = "ab\ncde\nfg"
        let spans = DiffHighlighter.perLineSpans(
            text: text, captures: [(NSRange(location: 4, length: 4), .string)])
        XCTAssertEqual(spans[2], [TokenSpan(range: NSRange(location: 1, length: 2), role: .string)])
        XCTAssertEqual(spans[3], [TokenSpan(range: NSRange(location: 0, length: 1), role: .string)])
        XCTAssertNil(spans[1])
    }

    func test_perLineSpans_emptyForNoCaptures() {
        XCTAssertTrue(DiffHighlighter.perLineSpans(text: "let x = 1", captures: []).isEmpty)
    }

    // MARK: - Real tree-sitter pipeline (CodeEditLanguages Swift grammar)

    func test_swiftSource_producesKeywordAndNumberAndFunctionRoles() throws {
        guard let (language, query) = SyntaxLanguage.resolve(path: "Sample.swift") else {
            return XCTFail("Swift grammar/query should resolve via CodeEditLanguages")
        }
        // Line 1: `let x = 42`  Line 2: `func greet() {}`
        let spans = DiffHighlighter.perLineSpans(
            text: "let x = 42\nfunc greet() {}\n", language: language, query: query)

        let line1 = spans[1] ?? []
        XCTAssertTrue(
            line1.contains { $0.role == .keyword && $0.range.location == 0 },
            "`let` should be a keyword at column 0 of line 1")
        XCTAssertTrue(line1.contains { $0.role == .number }, "`42` should be a number on line 1")

        let line2 = spans[2] ?? []
        XCTAssertTrue(
            line2.contains { $0.role == .keyword && $0.range.location == 0 },
            "`func` should be a keyword at column 0 of line 2")
    }

    func test_swiftSource_leavesPlainIdentifiersUnspanned() throws {
        guard let (language, query) = SyntaxLanguage.resolve(path: "Sample.swift") else {
            return XCTFail("Swift grammar should resolve")
        }
        // A bare identifier assignment has no keyword/type/number to color the identifier itself.
        let spans = DiffHighlighter.perLineSpans(text: "greeting = other\n", language: language, query: query)
        let colored = (spans[1] ?? []).filter { $0.range.location == 0 }
        XCTAssertTrue(colored.isEmpty, "a plain identifier at column 0 should not be colored")
    }
}
