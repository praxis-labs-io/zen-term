import XCTest

@testable import ZenTerm

final class PlaceholderSpanSourceTests: XCTestCase {
    func test_tokenize_tagsKeywordsAndBareIntegers() {
        let spans = PlaceholderSpanSource.tokenize("let x = 12")
        // "let" -> keyword [0,3); "12" -> number [8,2); "x" and the operators tag nothing.
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0], TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword))
        XCTAssertEqual(spans[1], TokenSpan(range: NSRange(location: 8, length: 2), role: .number))
    }

    func test_tokenize_nonKeywordIdentifiersTagNothing() {
        XCTAssertTrue(PlaceholderSpanSource.tokenize("greeting = helloWorld").isEmpty)
    }

    func test_spansForFile_keyOldByOldLineNumberAndNewByNewLineNumber() {
        let file = FileDiff(
            path: "F.swift", oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -4,2 +7,2 @@", oldStart: 4, newStart: 7,
                    lines: [
                        DiffLine(kind: .removed, oldLineNumber: 4, newLineNumber: nil, text: "var a = 1"),
                        DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 7, text: "let b = 2"),
                    ])
            ])

        let spans = PlaceholderSpanSource().spans(for: file)

        // Removed line is keyed on the old side by its old line number; added on the new side by its new.
        XCTAssertEqual(spans?.old(4)?.first?.role, .keyword)  // "var"
        XCTAssertNil(spans?.new(4))
        XCTAssertEqual(spans?.new(7)?.first?.role, .keyword)  // "let"
        XCTAssertNil(spans?.old(7))
    }

    func test_spansForFile_omitsLinesThatTagNothing() {
        let file = FileDiff(
            path: "F.swift", oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -1,1 +1,1 @@", oldStart: 1, newStart: 1,
                    lines: [DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "plain text here")])
            ])

        let spans = PlaceholderSpanSource().spans(for: file)
        XCTAssertNil(spans?.old(1))
        XCTAssertNil(spans?.new(1))
    }
}
