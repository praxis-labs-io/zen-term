import XCTest

@testable import ZenTerm

final class WorktreeFileChangeTests: XCTestCase {
    private func parse(_ records: [String]) -> [WorktreeFileChange] {
        WorktreeFileChange.parse(records.map { $0 + "\0" }.joined())
    }

    func test_parse_readsEachKindOfRecord() {
        let changes = parse([
            "1 .M N... 100644 100644 100644 aaa aaa edited.swift",
            "1 A. N... 000000 100644 100644 000 bbb added.swift",
            "1 D. N... 100644 000000 000000 aaa 000 gone.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc clash.swift",
            "? scratch/notes.md",
        ])

        XCTAssertEqual(
            changes,
            [
                WorktreeFileChange(path: "edited.swift", categories: [.modified]),
                WorktreeFileChange(path: "added.swift", categories: [.staged]),
                WorktreeFileChange(path: "gone.swift", categories: [.deleted]),
                WorktreeFileChange(path: "clash.swift", categories: [.conflicted]),
                WorktreeFileChange(path: "scratch/notes.md", categories: [.untracked]),
            ])
    }

    func test_parse_keepsBothSidesOfAStagedFileEditedAgain() {
        let changes = parse(["1 MM N... 100644 100644 100644 aaa bbb both.swift"])

        XCTAssertEqual(changes, [WorktreeFileChange(path: "both.swift", categories: [.staged, .modified])])
    }

    func test_parse_keepsSpacesInsideAPath() {
        let changes = parse([
            "1 .M N... 100644 100644 100644 aaa aaa a b.txt",
            "? d/e/un tracked.txt",
        ])

        XCTAssertEqual(changes.map(\.path), ["a b.txt", "d/e/un tracked.txt"])
    }

    func test_parse_readsARenameByItsNewPathAndSkipsTheOldOne() {
        let changes = parse([
            "2 R. N... 100644 100644 100644 aaa aaa R100 new name.txt", "? looks-untracked.txt",
            "? after.txt",
        ])

        XCTAssertEqual(
            changes,
            [
                WorktreeFileChange(path: "new name.txt", categories: [.renamed]),
                WorktreeFileChange(path: "after.txt", categories: [.untracked]),
            ])
    }

    func test_parse_cleanTreeIsEmpty() {
        XCTAssertEqual(WorktreeFileChange.parse(""), [])
    }
}
