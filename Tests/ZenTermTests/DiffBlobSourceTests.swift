import XCTest

@testable import ZenTerm

final class DiffBlobSourceTests: XCTestCase {
    private func file(
        path: String = "A.swift", oldPath: String? = nil, scope: DiffScope, baseSHA: String? = nil
    ) -> FileDiff {
        FileDiff(path: path, oldPath: oldPath, changeKind: .modified, hunks: [], scope: scope, baseSHA: baseSHA)
    }

    func test_unstaged_oldIsIndexBlob_newIsWorkingTree() {
        XCTAssertEqual(
            GitDiffRunner.blobSource(for: file(scope: .unstaged), side: .old), .git(["show", ":A.swift"]))
        XCTAssertEqual(
            GitDiffRunner.blobSource(for: file(scope: .unstaged), side: .new), .workingTree(path: "A.swift"))
    }

    func test_staged_oldIsHead_newIsIndex() {
        XCTAssertEqual(
            GitDiffRunner.blobSource(for: file(scope: .staged), side: .old), .git(["show", "HEAD:A.swift"]))
        XCTAssertEqual(
            GitDiffRunner.blobSource(for: file(scope: .staged), side: .new), .git(["show", ":A.swift"]))
    }

    func test_committed_oldIsBaseSHA_newIsHead() {
        let committed = file(scope: .committed, baseSHA: "abc1234")
        XCTAssertEqual(GitDiffRunner.blobSource(for: committed, side: .old), .git(["show", "abc1234:A.swift"]))
        XCTAssertEqual(GitDiffRunner.blobSource(for: committed, side: .new), .git(["show", "HEAD:A.swift"]))
    }

    func test_committed_withoutBaseSHA_oldSideHasNoSource() {
        XCTAssertNil(GitDiffRunner.blobSource(for: file(scope: .committed, baseSHA: nil), side: .old))
    }

    func test_rename_oldSideUsesOldPath_newSideUsesCurrentPath() {
        let renamed = file(path: "New.swift", oldPath: "Old.swift", scope: .committed, baseSHA: "sha")
        XCTAssertEqual(GitDiffRunner.blobSource(for: renamed, side: .old), .git(["show", "sha:Old.swift"]))
        XCTAssertEqual(GitDiffRunner.blobSource(for: renamed, side: .new), .git(["show", "HEAD:New.swift"]))
    }
}
