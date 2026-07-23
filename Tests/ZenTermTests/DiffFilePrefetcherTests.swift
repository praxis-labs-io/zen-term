import XCTest

@testable import ZenTerm

final class DiffFilePrefetcherTests: XCTestCase {
    private func file(_ path: String, scope: DiffScope = .unstaged) -> FileDiff {
        FileDiff(path: path, oldPath: nil, changeKind: .modified, hunks: [], scope: scope)
    }

    private func status(unstaged: [FileDiff] = [], staged: [FileDiff] = [], committed: [FileDiff] = [])
        -> GitDiffRunner.StatusLoad
    {
        GitDiffRunner.StatusLoad(
            unstaged: unstaged, staged: staged, committed: committed,
            baseBranch: nil, baseSHA: nil, currentBranch: nil)
    }

    func test_candidates_spanAllThreeSlices_excludingSelectedAndUnsupported() {
        let load = status(
            unstaged: [file("A.swift"), file("notes.xyzzy")],  // unknown language → never highlights
            staged: [file("B.swift", scope: .staged)],
            committed: [file("C.swift", scope: .committed)])

        let paths = DiffFilePrefetcher.candidates(
            in: load, excluding: file("A.swift").highlightKey, store: DiffHighlightStore()
        ).map(\.path)

        XCTAssertEqual(
            Set(paths), ["B.swift", "C.swift"], "excludes the selected file and the unsupported language")
    }

    func test_candidates_sameNameInTwoSlicesAreDistinctCandidates() {
        // A file changed both in the working tree and since the base appears in Unstaged and Committed
        // with the same path; each is its own candidate (different blobs), keyed by highlightKey.
        let load = status(
            unstaged: [file("A.swift")], committed: [file("A.swift", scope: .committed)])
        let candidates = DiffFilePrefetcher.candidates(in: load, excluding: nil, store: DiffHighlightStore())
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(Set(candidates.map(\.scope)), [.unstaged, .committed])
    }

    func test_candidates_skipsFilesAlreadyInTheStore() {
        let store = DiffHighlightStore()
        store.store(file("B.swift").highlightKey, nil)  // already resolved — don't re-prefetch
        let load = status(unstaged: [file("A.swift"), file("B.swift")])

        let paths = DiffFilePrefetcher.candidates(in: load, excluding: nil, store: store).map(\.path)

        XCTAssertEqual(paths, ["A.swift"])
    }

    func test_candidates_emptyWhenNothingToPrefetch() {
        XCTAssertTrue(DiffFilePrefetcher.candidates(in: status(), excluding: nil, store: DiffHighlightStore()).isEmpty)
    }
}
