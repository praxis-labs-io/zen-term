import XCTest

@testable import ZenTerm

final class AcknowledgementsTests: XCTestCase {
    func test_stripsHeadingMarkersAndBold() {
        let out = Acknowledgements.plainText(fromMarkdown: "### FreeType\n\n**FreeType License (FTL)**")
        XCTAssertEqual(out, "FreeType\n\nFreeType License (FTL)")
    }

    func test_dropsFenceDelimitersButKeepsTheBodyVerbatim() {
        let md = "Body:\n\n```text\n    Copyright 1996 by\n      David Turner\n```\n"
        let out = Acknowledgements.plainText(fromMarkdown: md)
        XCTAssertEqual(out, "Body:\n\n    Copyright 1996 by\n      David Turner\n")
    }

    func test_doesNotTouchHashOrBoldInsideAFence() {
        let md = "```text\n#define FOO 1\nweight **must** stay\n```"
        let out = Acknowledgements.plainText(fromMarkdown: md)
        XCTAssertEqual(out, "#define FOO 1\nweight **must** stay")
    }

    func test_leavesPlainProseAndBlankLinesAlone() {
        let md = "The terminal engine ZenTerm embeds.\n\nEverything reaches it through libghostty."
        XCTAssertEqual(Acknowledgements.plainText(fromMarkdown: md), md)
    }

    func test_unfencedLicenseText_survives_evenThoughItShouldBeFenced() {
        let md = "#define STBI_VERSION 1\n** Copyright (c) 2016 Ryan McIntyre. All rights reserved."
        XCTAssertEqual(Acknowledgements.plainText(fromMarkdown: md), md)
    }

    func test_onlyPairedBoldIsUnwrapped() {
        XCTAssertEqual(
            Acknowledgements.plainText(fromMarkdown: "**MIT** then a lone ** star"),
            "MIT then a lone ** star")
    }

    func test_realNoticesFile_everyFencedLicenseLineSurvivesVerbatim() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notices = repoRoot.appendingPathComponent("Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md")
        let markdown = try String(contentsOf: notices, encoding: .utf8)
        let outLines = Set(Acknowledgements.plainText(fromMarkdown: markdown).components(separatedBy: "\n"))

        var inFence = false
        var checked = 0
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard inFence else { continue }
            XCTAssertTrue(outLines.contains(line), "fenced license line was dropped or altered: \(line)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100, "expected the real notices to carry many fenced license lines")
    }

    func test_everyBundledTheme_isNamedInTheNotices() throws {
        let markdown = try String(contentsOf: Self.noticesURL, encoding: .utf8)
        for entry in ThemeCatalog.bundled {
            XCTAssertTrue(
                markdown.contains(entry.token),
                "\(entry.displayName) ships with no attribution in THIRD-PARTY-NOTICES.md")
        }
    }

    func test_theThemeCatalogAndTheShippedFiles_agree() throws {
        let dir = Self.repoRoot.appendingPathComponent("Sources/ZenTerm/Themes")
        let onDisk = Set(
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".ghostty") }
                .map { String($0.dropLast(".ghostty".count)) })
        XCTAssertEqual(Set(ThemeCatalog.bundled.map(\.token)), onDisk)
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let noticesURL =
        repoRoot
        .appendingPathComponent("Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md")
}
