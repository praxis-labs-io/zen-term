import XCTest

@testable import ZenTerm

final class SyntaxLanguageTests: XCTestCase {
    func test_resolve_bundledLanguage_returnsGrammarAndQuery() {
        // Swift and JSON have their highlights.scm bundled (the spike languages).
        XCTAssertNotNil(SyntaxLanguage.resolve(path: "Foo.swift"))
        XCTAssertNotNil(SyntaxLanguage.resolve(path: "data.json"))
    }

    func test_resolve_detectedButUnbundledLanguage_returnsNil() {
        // Python is detected by CodeEditLanguages, but until its query is bundled the file renders plain.
        XCTAssertNil(SyntaxLanguage.resolve(path: "script.py"))
    }

    func test_resolve_unknownExtension_returnsNil() {
        XCTAssertNil(SyntaxLanguage.resolve(path: "notes.xyz"))
        XCTAssertNil(SyntaxLanguage.resolve(path: "noextension"))
    }

    func test_role_mapsCaptureHeadComponentToRole() {
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["keyword", "function"]), .keyword)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["string"]), .string)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["comment"]), .comment)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["number"]), .number)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["float"]), .number)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["type", "builtin"]), .type)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["function", "method"]), .function)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["punctuation", "bracket"]), .punctuation)
    }

    func test_role_unmappedCaptureReturnsNil() {
        XCTAssertNil(SyntaxLanguage.role(forCapture: ["variable"]))
        XCTAssertNil(SyntaxLanguage.role(forCapture: ["property"]))
        XCTAssertNil(SyntaxLanguage.role(forCapture: []))
    }
}
