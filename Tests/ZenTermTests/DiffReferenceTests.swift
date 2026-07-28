import XCTest

@testable import ZenTerm

/// The `@path:line` string a yank or a comment carries (ZEN-227). Pure string shaping, and wrong in
/// ways nothing on screen shows: a range rendered as `42-42`, a deleted file handed line numbers that
/// no longer exist, or a missing `@` that stops the agent treating it as a file — all look fine in the
/// viewer and send the agent somewhere useless.
final class DiffReferenceTests: XCTestCase {
    private func selection(
        lines: [String] = ["x"], new: ClosedRange<Int>?, old: ClosedRange<Int>? = nil, anchor: Int? = nil
    ) -> DiffSelection {
        DiffSelection(lines: lines, newRange: new, oldRange: old, anchorNewLine: anchor)
    }

    func test_rangeAndSingleLineRenderDifferently() {
        XCTAssertEqual(
            DiffReference.string(path: "a/b.swift", changeKind: .modified, selection: selection(new: 42...44)),
            "@a/b.swift:42-44")
        XCTAssertEqual(
            DiffReference.string(path: "a/b.swift", changeKind: .modified, selection: selection(new: 42...42)),
            "@a/b.swift:42", "a one-line range must not render as 42-42")
    }

    func test_removalsOnly_useTheAnchorLine() {
        XCTAssertEqual(
            DiffReference.string(
                path: "a/b.swift", changeKind: .modified, selection: selection(new: nil, old: 12...14, anchor: 11)),
            "@a/b.swift:11")
    }

    func test_removalAtTheTopOfAFile_fallsBackToLineOne() {
        XCTAssertEqual(
            DiffReference.string(
                path: "a/b.swift", changeKind: .modified, selection: selection(new: nil, old: 1...2, anchor: nil)),
            "@a/b.swift:1")
    }

    func test_deletedFileGetsNoLineNumbers() {
        // The old-side numbers are real, but the file isn't on disk — naming a line would point the
        // agent at whatever now occupies it.
        XCTAssertEqual(
            DiffReference.string(
                path: "a/gone.swift", changeKind: .deleted, selection: selection(new: nil, old: 1...9, anchor: 3)),
            "@a/gone.swift")
    }

    func test_emptySelectionIsJustThePath() {
        // A binary file parses to no rows at all, so there's nothing to select.
        XCTAssertEqual(
            DiffReference.string(
                path: "assets/icon.png", changeKind: .binary,
                selection: selection(lines: [], new: nil)),
            "@assets/icon.png")
    }

    func test_addedFileStillGetsItsRange() {
        XCTAssertEqual(
            DiffReference.string(path: "a/new.swift", changeKind: .added, selection: selection(new: 1...30)),
            "@a/new.swift:1-30")
    }
}
