import XCTest

@testable import ZenTerm

final class SyntaxLanguageTests: XCTestCase {
    func test_resolve_bundledLanguages_returnGrammarAndQuery() {
        // Every grammar CodeEditLanguages ships now has its query bundled, so the majors all resolve.
        for path in [
            "Foo.swift", "data.json", "app.js", "app.jsx",  // jsx shares the javascript grammar
            "app.ts", "app.tsx",  // tsx shares the typescript grammar
            "Config.toml", "init.lua", "README.md", "script.py", "main.rs", "main.go",
            "main.c", "main.cpp", "Main.java", "app.rb", "run.sh", "index.html", "style.css",
            "config.yaml", "index.php", "Program.cs", "App.kt", "query.sql", "main.zig",
        ] {
            XCTAssertNotNil(SyntaxLanguage.resolve(path: path), "\(path) should resolve to a bundled query")
            XCTAssertTrue(SyntaxLanguage.isSupported(path: path), "\(path) should report supported")
        }
    }

    func test_resolve_unknownLanguage_returnsNil() {
        XCTAssertNil(SyntaxLanguage.resolve(path: "notes.xyzzy"))
        XCTAssertFalse(SyntaxLanguage.isSupported(path: "notes.xyzzy"))
    }

    func test_isSupported_agreesWithResolve() {
        // The viewer withholds the first paint for anything `isSupported` claims, so a file it calls
        // supported but `resolve` can't actually highlight would stall on the safety cap.
        for path in [
            "Foo.swift", "data.json", "app.ts", "README.md", "script.py", "main.rs", "run.sh",
            "notes.xyzzy", "noextension", "Config.toml",
        ] {
            XCTAssertEqual(
                SyntaxLanguage.isSupported(path: path), SyntaxLanguage.resolve(path: path) != nil,
                "isSupported must match resolve for \(path)")
        }
    }

    func test_typescript_inheritsJavaScriptPatterns() throws {
        // TS's own query has no string/comment/function patterns — those come from the inherited
        // JavaScript query. Without the inheritance a .ts file highlights almost nothing.
        guard let (language, query) = SyntaxLanguage.resolve(path: "app.ts") else {
            return XCTFail("TypeScript should resolve")
        }
        let spans = DiffHighlighter.perLineSpans(
            text: "// note\nconst greeting: string = \"hi\"\n", language: language, query: query)

        XCTAssertTrue((spans[1] ?? []).contains { $0.role == .comment }, "JS comment pattern should apply")
        let line2 = spans[2] ?? []
        XCTAssertTrue(line2.contains { $0.role == .string }, "JS string pattern should apply")
        XCTAssertTrue(line2.contains { $0.role == .type }, "TS's own `string` type annotation should apply")
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

    func test_role_mapsMarkdownTextCaptures() {
        // Markdown's query is nearly all `text.*` — these carry its color.
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["text", "title"]), .keyword)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["text", "literal"]), .string)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["text", "uri"]), .string)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["text", "reference"]), .function)
        XCTAssertNil(SyntaxLanguage.role(forCapture: ["text"]), "bare @text stays plain")
    }

    func test_role_mapsCapturesIntroducedByTheNewerGrammars() {
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["escape"]), .string)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["preproc"]), .keyword)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["attribute"]), .type)
        XCTAssertEqual(SyntaxLanguage.role(forCapture: ["constant", "builtin"]), .number)
    }

    func test_role_unmappedCaptureReturnsNil() {
        // Identifiers read better plain; `property` in particular would make every JS/TS member loud.
        XCTAssertNil(SyntaxLanguage.role(forCapture: ["variable"]))
        XCTAssertNil(SyntaxLanguage.role(forCapture: ["property"]))
        XCTAssertNil(SyntaxLanguage.role(forCapture: ["parameter"]))
        XCTAssertNil(SyntaxLanguage.role(forCapture: ["none"]))
        XCTAssertNil(SyntaxLanguage.role(forCapture: []))
    }
}
