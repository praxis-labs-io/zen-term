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

    // MARK: - Content detection for extensionless files (ZEN-329)

    func test_resolve_shebang_resolvesAnExtensionlessScript() {
        XCTAssertNotNil(
            SyntaxLanguage.resolve(path: "bin/release", content: "#!/bin/bash\necho hi\n"),
            "a bash shebang should resolve a script with no extension")
    }

    func test_resolve_envShebang_resolvesTheInterpreterAfterEnv() {
        XCTAssertNotNil(
            SyntaxLanguage.resolve(path: "bin/lint", content: "#!/usr/bin/env python3\nprint(1)\n"),
            "env shebangs carry the interpreter as the next token")
    }

    func test_resolve_zshShebang_resolvesViaTheBashAlias() {
        // CodeEditLanguages' tables know `sh` and `bash` but not `zsh`; the alias shim covers it,
        // since the dependency's tables aren't ours to edit.
        XCTAssertNotNil(SyntaxLanguage.resolve(path: "bin/setup", content: "#!/bin/zsh\necho hi\n"))
        XCTAssertNotNil(SyntaxLanguage.resolve(path: "bin/setup", content: "#!/usr/bin/env zsh\necho hi\n"))
    }

    func test_resolve_emacsModeline_resolvesAnExtensionlessFile() {
        XCTAssertNotNil(
            SyntaxLanguage.resolve(path: "postinstall", content: "# -*- mode: python -*-\nprint(1)\n"),
            "an Emacs modeline names the language when the path can't")
    }

    func test_resolve_keyValueConfigContent_staysPlain() {
        // Deliberately no content-shape sniffing: an ambiguous key=value config maps to no grammar
        // correctly (unquoted values are TOML parse errors), so plain is the right answer.
        XCTAssertNil(
            SyntaxLanguage.resolve(path: "workspaces", content: "[ZenTerm]\npath = ~/Dev/zen-term\n"))
    }

    func test_resolve_crlfShebang_resolvesViaTheBashAlias() {
        // Swift treats "\r\n" as a *single* grapheme cluster, so splitting on "\n" doesn't split a
        // CRLF file at all. The "first line" swallows the rest of the file and the interpreter token
        // came out as `zsh\r\necho`. Split on `isNewline` and tokenize on `isWhitespace` instead.
        XCTAssertNotNil(
            SyntaxLanguage.resolve(path: "bin/setup", content: "#!/bin/zsh\r\necho hi\r\n"),
            "a CRLF-authored zsh script must still resolve")
        XCTAssertNotNil(
            SyntaxLanguage.resolve(path: "bin/setup", content: "#!/usr/bin/env zsh\r\necho hi\r\n"))
    }

    func test_resolve_zshExtension_resolvesViaTheBashAlias() {
        // `.zsh` is the commonest way a zsh file is named, and CodeEditLanguages' bash definition
        // lists `sh`/`bash` only. Without the alias reaching unknown *extensions*, `setup.zsh` renders
        // plain while the extensionless `setup` with the same shebang highlights.
        XCTAssertNotNil(SyntaxLanguage.resolve(path: "setup.zsh"))
        XCTAssertTrue(SyntaxLanguage.isSupported(path: "setup.zsh"))
    }

    func test_mayHighlight_matchesTheDisjunctionItReplaces() {
        // It is written in reduced form to evaluate `isSupported` once, so the equivalence is the thing
        // that can silently break: drift here either stalls a file on the withhold path or refuses one
        // that would have highlighted.
        for path in [
            "Foo.swift", "run.sh", "setup.zsh", "bin/release", ".zshrc", "notes.xyzzy", "Makefile",
            "workspaces", "app.ts",
        ] {
            XCTAssertEqual(
                SyntaxLanguage.mayHighlight(path: path),
                SyntaxLanguage.isSupported(path: path) || SyntaxLanguage.isContentDetectable(path: path),
                "mayHighlight must equal the disjunction for \(path)")
        }
    }

    func test_detectionBuffers_areBoundedForAHugeSingleLineBlob() {
        // The buffers exist to carry a shebang and a modeline, not the file. A blob with no newline at
        // all (a minified bundle) used to hand the whole string to the modeline regexes, ahead of the
        // 256 KB parse ceiling that was supposed to bound highlight work.
        let huge = String(repeating: "x", count: 4 * 1024 * 1024)
        let (prefix, suffix) = SyntaxLanguage.detectionBuffers(huge)
        XCTAssertLessThan(prefix?.count ?? 0, 64 * 1024, "the prefix buffer must not be the whole blob")
        XCTAssertLessThan(suffix?.count ?? 0, 64 * 1024, "the suffix buffer must not be the whole blob")
    }

    func test_detectionBuffers_stillCarryAShebangAndATrailingModeline() {
        // Bounding the buffers must not cost the two signals they exist for. The body has to clear the
        // budget at both ends, or the whole blob comes back as the prefix and the suffix is never
        // exercised.
        let content = "#!/bin/bash\n" + String(repeating: "echo hi\n", count: 4000) + "# -*- mode: sh -*-\n"
        let (prefix, suffix) = SyntaxLanguage.detectionBuffers(content)
        XCTAssertTrue(prefix?.hasPrefix("#!/bin/bash") ?? false, "the shebang must survive the bound")
        XCTAssertTrue(suffix?.contains("mode: sh") ?? false, "a trailing modeline must survive the bound")
    }

    func test_detectionBuffers_shortBlobIsCarriedWhole() {
        // Under the budget there is nothing to trim, and the modeline detection reads the prefix first,
        // so a small file needs no suffix at all.
        let (prefix, suffix) = SyntaxLanguage.detectionBuffers("#!/bin/bash\necho hi\n")
        XCTAssertEqual(prefix, "#!/bin/bash\necho hi\n")
        XCTAssertNil(suffix)
    }

    func test_resolve_withoutContent_stillAnswersFromThePathAlone() {
        XCTAssertNotNil(SyntaxLanguage.resolve(path: "Foo.swift"))
        XCTAssertNil(SyntaxLanguage.resolve(path: "bin/release"))
    }

    func test_isContentDetectable_onlyForExtensionlessUnsupportedPaths() {
        XCTAssertTrue(SyntaxLanguage.isContentDetectable(path: "bin/release"))
        XCTAssertTrue(SyntaxLanguage.isContentDetectable(path: ".zshrc"), "a dotfile has no extension")
        XCTAssertFalse(
            SyntaxLanguage.isContentDetectable(path: "Foo.swift"),
            "a path-supported file takes the withhold-paint path instead")
        XCTAssertFalse(
            SyntaxLanguage.isContentDetectable(path: "notes.xyzzy"),
            "an unknown extension is a real answer: plain, no content pass")
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
