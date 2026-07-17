import XCTest

@testable import ZenTerm

final class AcknowledgementsTests: XCTestCase {
    func test_stripsHeadingMarkersAndBold() {
        let out = Acknowledgements.plainText(fromMarkdown: "### FreeType\n\n**FreeType License (FTL)**")
        XCTAssertEqual(out, "FreeType\n\nFreeType License (FTL)")
    }

    func test_dropsFenceDelimitersButKeepsTheBodyVerbatim() {
        // The indentation inside a fence is license text and must survive untouched.
        let md = "Body:\n\n```text\n    Copyright 1996 by\n      David Turner\n```\n"
        let out = Acknowledgements.plainText(fromMarkdown: md)
        XCTAssertEqual(out, "Body:\n\n    Copyright 1996 by\n      David Turner\n")
    }

    func test_doesNotTouchHashOrBoldInsideAFence() {
        // A `#` at the start of a fenced line (e.g. a C preprocessor line, or a license that uses
        // it) is content, not a heading — the fence guard must protect it.
        let md = "```text\n#define FOO 1\nweight **must** stay\n```"
        let out = Acknowledgements.plainText(fromMarkdown: md)
        XCTAssertEqual(out, "#define FOO 1\nweight **must** stay")
    }

    func test_leavesPlainProseAndBlankLinesAlone() {
        let md = "The terminal engine ZenTerm embeds.\n\nEverything reaches it through libghostty."
        XCTAssertEqual(Acknowledgements.plainText(fromMarkdown: md), md)
    }

    func test_unfencedLicenseText_survives_evenThoughItShouldBeFenced() {
        // Guards the invariant the transform quietly depends on: even if a maintainer pastes a
        // license as prose rather than in a fence, the strip must not rewrite it. A `#` without a
        // following space is not a heading, and an unpaired `**` banner is not our bold label.
        let md = "#define STBI_VERSION 1\n** Copyright (c) 2016 Ryan McIntyre. All rights reserved."
        XCTAssertEqual(Acknowledgements.plainText(fromMarkdown: md), md)
    }

    func test_onlyPairedBoldIsUnwrapped() {
        XCTAssertEqual(
            Acknowledgements.plainText(fromMarkdown: "**MIT** then a lone ** star"),
            "MIT then a lone ** star")
    }

    func test_realNoticesFile_everyFencedLicenseLineSurvivesVerbatim() throws {
        // The finding this test answers: the other cases use tiny synthetic strings, so nothing
        // exercised the real 3600-line notices against the fencing invariant. Run the actual shipped
        // file and assert every fenced line — the verbatim license text — appears unchanged.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ZenTermTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
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
}
