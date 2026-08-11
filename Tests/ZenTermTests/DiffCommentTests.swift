import XCTest

@testable import ZenTerm

/// What actually lands in the agent's input. The composition rule is the whole contract of
/// the feature: get it wrong and the reference points at the wrong thing, or the removed lines the
/// agent can't read anywhere else are silently dropped.
final class DiffCommentTests: XCTestCase {
    func test_referenceLeadsTheNote() {
        XCTAssertEqual(
            DiffComment.message(reference: "Sources/App/Foo.swift:42-44", note: "reuse centerRow here"),
            "Sources/App/Foo.swift:42-44 reuse centerRow here")
    }

    func test_noNote_sendsTheBareReference() {
        // Select, ⏎, ⏎ — the fast path that just puts a line range in the input.
        XCTAssertEqual(
            DiffComment.message(reference: "Sources/App/Foo.swift:42", note: ""),
            "Sources/App/Foo.swift:42")
    }

    func test_aNoteOfOnlyWhitespace_countsAsNoNote() {
        XCTAssertEqual(
            DiffComment.message(reference: "Foo.swift:1", note: "   \n  "),
            "Foo.swift:1",
            "no trailing space left hanging off the reference")
    }

    func test_theNoteIsTrimmedButItsOwnLineBreaksSurvive() {
        // ⌥⏎ puts real newlines in the note, and bracketed paste delivers them as one block — so
        // interior breaks are content, and only the edges are noise.
        XCTAssertEqual(
            DiffComment.message(reference: "Foo.swift:1", note: "  first\nsecond  "),
            "Foo.swift:1 first\nsecond")
    }

    func test_removedLinesRideAlong_becauseTheyreInNoFileToRead() {
        let message = DiffComment.message(
            reference: "Sources/App/Foo.swift:41", note: "why did this go?",
            removedLines: ["    func gone() {", "    }"])
        XCTAssertEqual(
            message,
            """
            Sources/App/Foo.swift:41 why did this go?

            Removed lines:
                func gone() {
                }
            """)
    }

    func test_removedLinesKeepTheirOwnIndentation() {
        let message = DiffComment.message(
            reference: "Foo.swift:1", note: "", removedLines: ["        deep()"])
        XCTAssertTrue(
            message.hasSuffix("\n        deep()"),
            "re-indenting would corrupt code the agent is being asked to read")
    }

    func test_noRemovedLines_addsNoTrailer() {
        XCTAssertEqual(
            DiffComment.message(reference: "Foo.swift:1", note: "look", removedLines: []),
            "Foo.swift:1 look")
    }
}
