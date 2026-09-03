import XCTest

@testable import ZenTerm

/// The confirm's wording. One dialog carries both consequences — the work that goes and the tabs
/// that close — so the string has to stay readable across every combination of the two.
///
/// Worth a test rather than the runbook because it is assembled from counts: the eye checks it in
/// one state, and the plural and the "is/are" go wrong in another.
final class RemoveCloneMessageTests: XCTestCase {
    private let clone = Clone(
        workspaceTitle: "zen-term", name: "c2",
        path: URL(fileURLWithPath: "/tmp/clones/zen-term/zen-term-c2"), branch: "main")

    private func message(uncommitted: Int, unpushed: Int, openTabs: Int) -> String {
        WindowController.removeCloneMessage(
            clone, state: CloneState(uncommitted: uncommitted, unpushed: unpushed), openTabs: openTabs)
    }

    func test_clean_andNotOpen_namesTheDirectory() {
        XCTAssertEqual(
            message(uncommitted: 0, unpushed: 0, openTabs: 0),
            "zen-term c2 has nothing uncommitted. Removing it deletes the directory.")
    }

    func test_clean_andOpen_saysTheTabCloses() {
        XCTAssertEqual(
            message(uncommitted: 0, unpushed: 0, openTabs: 1),
            "zen-term c2 has nothing uncommitted. Removing it closes its tab and deletes the directory.")
    }

    func test_dirty_namesBothCounts() {
        XCTAssertEqual(
            message(uncommitted: 4, unpushed: 2, openTabs: 0),
            "zen-term c2 has 4 uncommitted files and 2 commits that are on no remote. "
                + "Removing it deletes them.")
    }

    func test_dirty_andOpenInSeveralTabs_carriesBothConsequences() {
        XCTAssertEqual(
            message(uncommitted: 1, unpushed: 1, openTabs: 3),
            "zen-term c2 has 1 uncommitted file and 1 commit that is on no remote. "
                + "Removing it closes its 3 tabs and deletes them.")
    }

    /// Only one side dirty: the sentence must not carry an empty half or a stray "and".
    func test_onlyUncommitted_omitsTheCommitClause() {
        XCTAssertEqual(
            message(uncommitted: 2, unpushed: 0, openTabs: 0),
            "zen-term c2 has 2 uncommitted files. Removing it deletes them.")
    }

    func test_onlyUnpushed_omitsTheFileClause() {
        XCTAssertEqual(
            message(uncommitted: 0, unpushed: 5, openTabs: 0),
            "zen-term c2 has 5 commits that are on no remote. Removing it deletes them.")
    }

    /// `docs/brand-voice.md`: state the consequence, never ask, and no em-dashes anywhere.
    func test_everyWording_followsTheVoice() {
        for tabs in 0...2 {
            for (uncommitted, unpushed) in [(0, 0), (1, 0), (0, 1), (3, 4)] {
                let text = message(uncommitted: uncommitted, unpushed: unpushed, openTabs: tabs)
                XCTAssertFalse(text.contains("—"), "no em-dashes: \(text)")
                XCTAssertFalse(text.lowercased().contains("are you sure"), text)
                XCTAssertFalse(text.contains("  "), "no doubled space from an empty clause: \(text)")
                XCTAssertTrue(text.hasSuffix("."), text)
            }
        }
    }
}
