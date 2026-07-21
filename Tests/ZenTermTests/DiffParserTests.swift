import XCTest

@testable import ZenTerm

final class DiffParserTests: XCTestCase {
    func test_parse_singleModifiedFile_pathKindAndCounts() {
        let diff = """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1234567..89abcde 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1,4 +1,4 @@
             import Foundation
            -let x = 1
            +let x = 2
             let y = 3
             let z = 4
            """

        let files = DiffParser.parse(diff)

        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.path, "Sources/App.swift")
        XCTAssertNil(file.oldPath)
        XCTAssertEqual(file.changeKind, .modified)
        XCTAssertEqual(file.addedCount, 1)
        XCTAssertEqual(file.removedCount, 1)
        XCTAssertEqual(file.hunks.count, 1)
    }

    func test_parse_modifiedFile_assignsLineNumbers() {
        let diff = """
            diff --git a/App.swift b/App.swift
            index 1234567..89abcde 100644
            --- a/App.swift
            +++ b/App.swift
            @@ -1,4 +1,4 @@
             import Foundation
            -let x = 1
            +let x = 2
             let y = 3
             let z = 4
            """

        let hunk = DiffParser.parse(diff)[0].hunks[0]

        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.newStart, 1)
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removed, .added, .context, .context])

        let removed = hunk.lines[1]
        XCTAssertEqual(removed.text, "let x = 1")
        XCTAssertEqual(removed.oldLineNumber, 2)
        XCTAssertNil(removed.newLineNumber)

        let added = hunk.lines[2]
        XCTAssertEqual(added.text, "let x = 2")
        XCTAssertNil(added.oldLineNumber)
        XCTAssertEqual(added.newLineNumber, 2)

        let lastContext = hunk.lines[4]
        XCTAssertEqual(lastContext.oldLineNumber, 4)
        XCTAssertEqual(lastContext.newLineNumber, 4)
    }

    func test_parse_addedFile_isAddedKind() {
        let diff = """
            diff --git a/New.swift b/New.swift
            new file mode 100644
            index 0000000..89abcde
            --- /dev/null
            +++ b/New.swift
            @@ -0,0 +1,2 @@
            +line one
            +line two
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.path, "New.swift")
        XCTAssertNil(file.oldPath)
        XCTAssertEqual(file.changeKind, .added)
        XCTAssertEqual(file.addedCount, 2)
        XCTAssertEqual(file.removedCount, 0)
    }

    func test_parse_deletedFile_isDeletedKind() {
        let diff = """
            diff --git a/Gone.swift b/Gone.swift
            deleted file mode 100644
            index 89abcde..0000000
            --- a/Gone.swift
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -line one
            -line two
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.path, "Gone.swift")
        XCTAssertNil(file.oldPath)
        XCTAssertEqual(file.changeKind, .deleted)
        XCTAssertEqual(file.addedCount, 0)
        XCTAssertEqual(file.removedCount, 2)
    }

    func test_parse_renamedFile_setsOldPath() {
        let diff = """
            diff --git a/Old.swift b/New.swift
            similarity index 80%
            rename from Old.swift
            rename to New.swift
            index 1111111..2222222 100644
            --- a/Old.swift
            +++ b/New.swift
            @@ -1,2 +1,2 @@
             unchanged
            -old line
            +new line
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.path, "New.swift")
        XCTAssertEqual(file.oldPath, "Old.swift")
        XCTAssertEqual(file.changeKind, .renamed)
        XCTAssertEqual(file.addedCount, 1)
        XCTAssertEqual(file.removedCount, 1)
    }

    func test_parse_pureRename_noHunks_setsPaths() {
        let diff = """
            diff --git a/Old.swift b/Renamed.swift
            similarity index 100%
            rename from Old.swift
            rename to Renamed.swift
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.path, "Renamed.swift")
        XCTAssertEqual(file.oldPath, "Old.swift")
        XCTAssertEqual(file.changeKind, .renamed)
        XCTAssertTrue(file.hunks.isEmpty)
    }

    func test_parse_binaryFile_isBinaryKind() {
        let diff = """
            diff --git a/Logo.png b/Logo.png
            index 1111111..2222222 100644
            Binary files a/Logo.png and b/Logo.png differ
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.path, "Logo.png")
        XCTAssertEqual(file.changeKind, .binary)
        XCTAssertTrue(file.hunks.isEmpty)
    }

    func test_parse_multipleHunks_inOneFile() {
        let diff = """
            diff --git a/File.swift b/File.swift
            index 1111111..2222222 100644
            --- a/File.swift
            +++ b/File.swift
            @@ -1,2 +1,2 @@
             first
            -second
            +second changed
            @@ -20,2 +20,3 @@
             twenty
            +twenty-one
             twenty-two
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.hunks.count, 2)
        XCTAssertEqual(file.hunks[1].oldStart, 20)
        XCTAssertEqual(file.hunks[1].newStart, 20)
        XCTAssertEqual(file.addedCount, 2)
        XCTAssertEqual(file.removedCount, 1)
    }

    func test_parse_multipleFiles() {
        let diff = """
            diff --git a/A.swift b/A.swift
            index 1111111..2222222 100644
            --- a/A.swift
            +++ b/A.swift
            @@ -1 +1 @@
            -a
            +A
            diff --git a/B.swift b/B.swift
            index 3333333..4444444 100644
            --- a/B.swift
            +++ b/B.swift
            @@ -1 +1 @@
            -b
            +B
            """

        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.map(\.path), ["A.swift", "B.swift"])
    }

    func test_parse_noNewlineAtEOF_markerNotCounted() {
        let diff = """
            diff --git a/f.txt b/f.txt
            index 1111111..2222222 100644
            --- a/f.txt
            +++ b/f.txt
            @@ -1 +1 @@
            -old
            \\ No newline at end of file
            +new
            \\ No newline at end of file
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.addedCount, 1)
        XCTAssertEqual(file.removedCount, 1)
        XCTAssertEqual(file.hunks[0].lines.map(\.kind), [.removed, .added])
    }

    func test_parse_emptyDiff_returnsEmpty() {
        XCTAssertTrue(DiffParser.parse("").isEmpty)
    }

    // A removed line whose content starts with "-- " arrives as "--- content" and must not be
    // mistaken for a `---` file header (SQL/Lua/Haskell comments, patch files).
    func test_parse_removedLineStartingWithDoubleDash_notMistakenForHeader() {
        let diff = """
            diff --git a/q.sql b/q.sql
            index 1111111..2222222 100644
            --- a/q.sql
            +++ b/q.sql
            @@ -1,3 +1,2 @@
             SELECT 1;
            --- old comment
             SELECT 2;
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.path, "q.sql")
        XCTAssertEqual(file.changeKind, .modified)
        XCTAssertEqual(file.removedCount, 1)
        let removed = file.hunks[0].lines.first { $0.kind == .removed }
        XCTAssertEqual(removed?.text, "-- old comment")
        let lastLine = file.hunks[0].lines.last
        XCTAssertEqual(lastLine?.text, "SELECT 2;")
        XCTAssertEqual(lastLine?.oldLineNumber, 3)
    }

    // Symmetric case: an added line whose content starts with "++ " arrives as "+++ content"
    // and must not be mistaken for a `+++` header (which would drop it and mis-set the path).
    func test_parse_addedLineStartingWithDoublePlus_notMistakenForHeader() {
        let diff = """
            diff --git a/notes.patch b/notes.patch
            index 1111111..2222222 100644
            --- a/notes.patch
            +++ b/notes.patch
            @@ -1,1 +1,2 @@
             context line
            +++ b/some/added/file
            """

        let file = DiffParser.parse(diff)[0]
        XCTAssertEqual(file.path, "notes.patch")
        XCTAssertEqual(file.changeKind, .modified)
        XCTAssertEqual(file.addedCount, 1)
        let added = file.hunks[0].lines.first { $0.kind == .added }
        XCTAssertEqual(added?.text, "++ b/some/added/file")
    }
}
