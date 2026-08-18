import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SyntaxAttributedTextTests: XCTestCase {
    private let chrome = ChromeThemeDeriver.derive(from: Theme.rosePineDarker)
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func color(_ attributed: NSAttributedString, at index: Int) -> NSColor? {
        attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func test_make_colorsSpanRangesAndLeavesBaseElsewhere() {
        // "let x = 12": "let" is [0,3) keyword, "12" is [8,2) number, the rest stays base.
        let base = chrome.foreground.nsColor
        let attributed = SyntaxAttributedText.make(
            "let x = 12",
            spans: [
                TokenSpan(range: NSRange(location: 0, length: 3), role: .keyword),
                TokenSpan(range: NSRange(location: 8, length: 2), role: .number),
            ],
            base: base, font: font, chrome: chrome)

        XCTAssertEqual(attributed.length, 10)
        XCTAssertEqual(color(attributed, at: 0), chrome.synKeyword.nsColor)  // 'l' of "let"
        XCTAssertEqual(color(attributed, at: 4), base)  // 'x', unspanned
        XCTAssertEqual(color(attributed, at: 8), chrome.synNumber.nsColor)  // '1' of "12"
    }

    func test_make_preservesRunOrderingAcrossAdjacentSpans() {
        // Two touching spans keep their own colors, not the last-writer's, across the boundary.
        let attributed = SyntaxAttributedText.make(
            "ab",
            spans: [
                TokenSpan(range: NSRange(location: 0, length: 1), role: .keyword),
                TokenSpan(range: NSRange(location: 1, length: 1), role: .string),
            ],
            base: chrome.foreground.nsColor, font: font, chrome: chrome)

        XCTAssertEqual(color(attributed, at: 0), chrome.synKeyword.nsColor)
        XCTAssertEqual(color(attributed, at: 1), chrome.synString.nsColor)
    }

    func test_make_clampsSpanRunningPastTextEnd() {
        // A span whose range overruns the text (e.g. a stale parse against a longer revision) colors
        // only the in-range part and never indexes past the end.
        let base = chrome.foreground.nsColor
        let attributed = SyntaxAttributedText.make(
            "abcd",
            spans: [TokenSpan(range: NSRange(location: 2, length: 50), role: .keyword)],
            base: base, font: font, chrome: chrome)

        XCTAssertEqual(attributed.length, 4)
        XCTAssertEqual(color(attributed, at: 1), base)
        XCTAssertEqual(color(attributed, at: 3), chrome.synKeyword.nsColor)
    }

    func test_make_dropsSpanFullyOutsideText() {
        let base = chrome.foreground.nsColor
        let attributed = SyntaxAttributedText.make(
            "abcd",
            spans: [TokenSpan(range: NSRange(location: 100, length: 5), role: .keyword)],
            base: base, font: font, chrome: chrome)

        XCTAssertEqual(attributed.length, 4)
        for index in 0..<4 { XCTAssertEqual(color(attributed, at: index), base) }
    }

    func test_make_carriesTheLabelsClippingLineBreakMode() {
        // A diff line pans inside a clip and must never wrap. The label's own `.byClipping` only governs
        // `stringValue`; an attributed string carries its own paragraph style, and with none set it
        // inherits `.byWordWrapping` — which, with maximumNumberOfLines = 1, silently drops whole words
        // off the end of the line. That is the "missing text" bug, so assert the mode explicitly.
        let attributed = SyntaxAttributedText.make(
            "] as const;", spans: [TokenSpan(range: NSRange(location: 0, length: 1), role: .punctuation)],
            base: chrome.foreground.nsColor, font: font, chrome: chrome)

        let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.lineBreakMode, .byClipping, "attributed lines must clip, never wrap")
        XCTAssertNotEqual(
            NSParagraphStyle.default.lineBreakMode, .byClipping,
            "guard: the default really is a wrapping mode, so omitting the style would regress")
    }

    func test_flatColor_mapsKindToWholeLineColor() {
        XCTAssertEqual(SyntaxAttributedText.flatColor(for: .added, chrome: chrome), chrome.positive.nsColor)
        XCTAssertEqual(
            SyntaxAttributedText.flatColor(for: .removed, chrome: chrome), chrome.destructive.nsColor)
        XCTAssertEqual(
            SyntaxAttributedText.flatColor(for: .context, chrome: chrome), chrome.foreground.nsColor)
    }
}
