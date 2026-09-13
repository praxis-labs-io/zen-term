import XCTest

@testable import ZenTerm

final class WorktreeRemovalRollupTests: XCTestCase {
    private func files(_ paths: [String]) -> [WorktreeFileChange] {
        paths.map { WorktreeFileChange(path: $0, categories: [.modified]) }
    }

    private func labels(_ rows: [WorktreeRemovalRollup.Row]) -> [String] {
        rows.map { row in
            switch row {
            case .file(let file): return file.path
            case .folder(let path, let files): return "\(path)/ (\(files.count))"
            case .more(let hidden): return "and \(hidden) more"
            }
        }
    }

    func test_aListThatFits_showsEveryFileInPathOrder() {
        let rows = WorktreeRemovalRollup.rows(for: files(["b.txt", "src/a/x.swift", "a.txt"]))

        XCTAssertEqual(labels(rows), ["a.txt", "b.txt", "src/a/x.swift"])
    }

    func test_exactlyEightRows_neverRollsUp() {
        let paths = (1...8).map { "src/file\($0).swift" }

        XCTAssertEqual(labels(WorktreeRemovalRollup.rows(for: files(paths))), paths.sorted())
    }

    func test_theDeepestFolderRollsUpFirst_andOnlyAsFarAsNeeded() {
        let rows = WorktreeRemovalRollup.rows(
            for: files([
                "a.txt", "b.txt", "c.txt", "d.txt", "e.txt",
                "src/one.swift", "src/two.swift",
                "src/deep/one.swift", "src/deep/two.swift",
            ]))

        XCTAssertEqual(
            labels(rows),
            ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "src/deep/ (2)", "src/one.swift", "src/two.swift"])
    }

    func test_atEqualDepth_theFolderWithMoreFilesRollsUpFirst() {
        let rows = WorktreeRemovalRollup.rows(
            for: files([
                "a.txt", "b.txt", "c.txt", "d.txt",
                "few/one.txt", "few/two.txt",
                "many/one.txt", "many/two.txt", "many/three.txt",
            ]))

        XCTAssertEqual(
            labels(rows), ["a.txt", "b.txt", "c.txt", "d.txt", "few/one.txt", "few/two.txt", "many/ (3)"])
    }

    func test_aParentRollsUpAfterItsChild_andTakesTheChildWithIt() {
        let rows = WorktreeRemovalRollup.rows(
            for: files([
                "a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt",
                "build/manifest.json",
                "build/cache/one.bin", "build/cache/two.bin", "build/cache/three.bin",
                "build/solo/only.bin",
            ]))

        XCTAssertEqual(labels(rows), ["a.txt", "b.txt", "build/ (5)", "c.txt", "d.txt", "e.txt", "f.txt"])
    }

    func test_whatStillSpills_isCountedOnTheLastRow() {
        let paths = (1...10).map { "file\($0).txt" } + ["src/one.swift", "src/two.swift"]

        let rows = WorktreeRemovalRollup.rows(for: files(paths))

        XCTAssertEqual(rows.count, WorktreeRemovalRollup.rowLimit)
        XCTAssertEqual(labels(rows).last, "and 5 more")
    }
}
