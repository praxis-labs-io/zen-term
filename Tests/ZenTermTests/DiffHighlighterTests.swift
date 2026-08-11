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

    // MARK: - Size ceiling

    func test_sizeCeiling_acceptsSmallFile() {
        XCTAssertTrue(DiffHighlighter.isWithinSizeCeiling("let x = 1\nlet y = 2\n"))
    }

    /// Line count is not a ceiling. It used to be, at 2000, and it fired earlier than the byte cap for
    /// ordinary source: `WindowController.swift` went permanently plain the day it passed 2000 lines,
    /// while parsing in 54 ms off the main thread. A long file of short lines is cheap; the byte cap is
    /// what bounds the expensive case.
    func test_sizeCeiling_acceptsAFileWellOverTwoThousandLines() {
        let manyShortLines = String(repeating: "x\n", count: 5000)  // 10 KB, 5001 lines
        XCTAssertLessThan(manyShortLines.utf8.count, 256 * 1024, "well inside the byte ceiling")
        XCTAssertTrue(
            DiffHighlighter.isWithinSizeCeiling(manyShortLines),
            "a long file of short lines is cheap to parse and must still highlight")
    }

    func test_sizeCeiling_rejectsTooManyBytes() {
        let big = String(repeating: "x", count: 256 * 1024 + 1)
        XCTAssertFalse(DiffHighlighter.isWithinSizeCeiling(big))
    }

    /// A few very long lines is the shape that actually costs, and the byte cap catches it where a line
    /// cap never would.
    func test_sizeCeiling_rejectsAFewEnormousLines() {
        let minified = String(repeating: String(repeating: "x", count: 100 * 1024) + "\n", count: 3)
        XCTAssertFalse(DiffHighlighter.isWithinSizeCeiling(minified))
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

    // MARK: - Extensionless files resolve from the blob's content

    /// An unstaged file's new side reads the working tree directly, so a plain directory stands in for
    /// the repo; the old side's `git show` fails there and renders plain, which is fine — the shebang
    /// only needs one side.
    private func workingTree(containing name: String, contents: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zenterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return root
    }

    func test_enrichSync_highlightsAnExtensionlessShebangScript() throws {
        let repo = try workingTree(containing: "release", contents: "#!/bin/bash\nif true; then\n  echo hi\nfi\n")
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = FileDiff(path: "release", oldPath: nil, changeKind: .added, hunks: [], scope: .unstaged)

        let spans = DiffHighlighter.enrichSync(file: file, repoRoot: repo)

        XCTAssertNotNil(spans, "the shebang names bash, so the blob must highlight")
        XCTAssertTrue(
            (spans?.new[2] ?? []).contains { $0.role == .keyword && $0.range.location == 0 },
            "`if` should be a keyword at column 0 of line 2")
    }

    func test_enrichSync_leavesAnExtensionlessConfigPlain() throws {
        let repo = try workingTree(containing: "workspaces", contents: "[ZenTerm]\npath = ~/Dev/zen-term\n")
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = FileDiff(path: "workspaces", oldPath: nil, changeKind: .added, hunks: [], scope: .unstaged)

        XCTAssertNil(
            DiffHighlighter.enrichSync(file: file, repoRoot: repo),
            "no shebang, no modeline — an ambiguous config resolves to nothing and renders plain")
    }

    /// A real repo, so the old side resolves through `git show :path` rather than the working tree.
    /// Returns nil when git isn't on the box, so the suite skips rather than fails.
    private func gitRepo(committing name: String, contents: String) throws -> URL? {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zenterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        for args in [
            ["init", "--quiet"], ["config", "user.email", "t@example.com"], ["config", "user.name", "T"],
            ["add", name], ["commit", "--quiet", "-m", "seed"],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + args
            process.currentDirectoryURL = root
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
        }
        return root
    }

    func test_enrichSync_emptiedScript_stillHighlightsFromTheOldSide() throws {
        // Emptying a file (content deleted, file kept) makes the new-side blob "" rather than absent.
        // Sniffing that empty string resolves nothing, so the old side has to get a turn: it still
        // carries the shebang, and it is the side the reader is looking at as removed lines.
        guard let repo = try gitRepo(committing: "release", contents: "#!/bin/bash\nif true; then\n  echo hi\nfi\n")
        else { throw XCTSkip("git unavailable") }
        defer { try? FileManager.default.removeItem(at: repo) }
        try "".write(to: repo.appendingPathComponent("release"), atomically: true, encoding: .utf8)
        let file = FileDiff(path: "release", oldPath: nil, changeKind: .modified, hunks: [], scope: .unstaged)

        let spans = DiffHighlighter.enrichSync(file: file, repoRoot: repo)

        XCTAssertNotNil(spans, "the old blob's shebang still names bash")
        XCTAssertTrue(
            (spans?.old[2] ?? []).contains { $0.role == .keyword && $0.range.location == 0 },
            "`if` should be a keyword at column 0 of the old side's line 2")
    }

    // MARK: - Query predicates must actually gate their captures

    func test_swift_dottedAccessBase_isNotTaggedAsAType() throws {
        // Swift's query has `((navigation_expression (simple_identifier) @type) (#match? @type "^[A-Z]"))`.
        // Unresolved, that predicate fires on the base of *every* dotted access, so ordinary lowercase
        // identifiers (`chrome.background`, `file.path`) render in the type colour — which is most lines
        // of idiomatic Swift.
        guard let (language, query) = SyntaxLanguage.resolve(path: "Sample.swift") else {
            return XCTFail("Swift should resolve")
        }
        let spans = DiffHighlighter.perLineSpans(text: "chrome.background = other\n", language: language, query: query)

        let chrome = NSRange(location: 0, length: 6)
        XCTAssertFalse(
            (spans[1] ?? []).contains { $0.range == chrome && $0.role == .type },
            "`chrome` is lowercase, so the #match? guard must stop it being typed")
    }

    func test_typescript_lowercaseIdentifiers_areNotTaggedAsTypes() throws {
        // TypeScript's `((identifier) @type (#match? @type "^[A-Z]"))` is a bare identifier pattern:
        // unresolved it tags every identifier in the file as a type.
        guard let (language, query) = SyntaxLanguage.resolve(path: "app.ts") else {
            return XCTFail("TypeScript should resolve")
        }
        let spans = DiffHighlighter.perLineSpans(
            text: "const value = compute(input)\n", language: language, query: query)

        XCTAssertFalse(
            (spans[1] ?? []).contains { $0.role == .type },
            "no identifier on this line is capitalised, so none should be typed")
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
