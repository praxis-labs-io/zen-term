import XCTest

@testable import ZenTerm

/// The one sentence in front of a folder about to be deleted. Pure, so it is asserted directly
/// rather than through the confirm toast it feeds.
final class WorktreeRemovalConfirmTests: XCTestCase {
    private func worktree(branch: String? = "feature/zen-456") -> Worktree {
        Worktree(
            path: URL(fileURLWithPath: "/tmp/wt"), branch: branch,
            head: "0123456789abcdef", isLocked: false)
    }

    private func message(
        state: WorktreeState?, carried: [String] = [], openTabs: Int = 0, branch: String? = "feature/zen-456"
    ) -> String {
        WindowController.removeWorktreeMessage(
            worktree(branch: branch), state: state, carried: carried, openTabs: openTabs)
    }

    // MARK: what it holds

    func test_unreadableState_saysSo_andNeverThatItIsClean() {
        let out = message(state: nil)
        XCTAssertTrue(out.hasPrefix("feature/zen-456 could not be read, so what it holds is unknown."))
        XCTAssertFalse(out.contains("nothing uncommitted"))
    }

    func test_cleanWorktree_stillConfirms() {
        XCTAssertEqual(
            message(state: WorktreeState(uncommitted: 0, unpushed: 0)),
            "feature/zen-456 has nothing uncommitted. Removing it deletes the folder and keeps the branch.")
    }

    func test_uncommittedOnly_isCountedAndPluralized() {
        XCTAssertTrue(
            message(state: WorktreeState(uncommitted: 1, unpushed: 0))
                .hasPrefix("feature/zen-456 has 1 uncommitted file."))
        XCTAssertTrue(
            message(state: WorktreeState(uncommitted: 3, unpushed: 0))
                .hasPrefix("feature/zen-456 has 3 uncommitted files."))
    }

    func test_unpushedOnly_agreesWithItsVerb() {
        XCTAssertTrue(
            message(state: WorktreeState(uncommitted: 0, unpushed: 1))
                .hasPrefix("feature/zen-456 has 1 commit that is on no remote."))
        XCTAssertTrue(
            message(state: WorktreeState(uncommitted: 0, unpushed: 2))
                .hasPrefix("feature/zen-456 has 2 commits that are on no remote."))
    }

    func test_bothCounts_areJoined() {
        XCTAssertTrue(
            message(state: WorktreeState(uncommitted: 3, unpushed: 2))
                .hasPrefix("feature/zen-456 has 3 uncommitted files and 2 commits that are on no remote."))
    }

    func test_detachedWorktree_isNamedByItsShortHead() {
        XCTAssertTrue(
            message(state: WorktreeState(uncommitted: 0, unpushed: 0), branch: nil)
                .hasPrefix("0123456 has nothing uncommitted."))
    }

    // MARK: what removing it does

    func test_openTabs_areCountedAndPluralized() {
        let clean = WorktreeState(uncommitted: 0, unpushed: 0)
        XCTAssertTrue(message(state: clean, openTabs: 0).contains("Removing it deletes the folder"))
        XCTAssertTrue(message(state: clean, openTabs: 1).contains("Removing it closes its tab,"))
        XCTAssertTrue(message(state: clean, openTabs: 4).contains("Removing it closes its 4 tabs,"))
    }

    func test_carriedEntries_areNamed() {
        let clean = WorktreeState(uncommitted: 0, unpushed: 0)
        XCTAssertTrue(
            message(state: clean, carried: [".env"])
                .contains("deletes the folder with the .env it carries"))
        XCTAssertTrue(
            message(state: clean, carried: [".env", "node_modules"])
                .contains("deletes the folder with the .env and node_modules it carries"))
        XCTAssertTrue(
            message(state: clean, carried: [".env", "node_modules", ".venv"])
                .contains("deletes the folder with the .env, node_modules, and .venv it carries"))
    }

    func test_everyCase_saysTheBranchStays() {
        let cases = [
            message(state: nil),
            message(state: WorktreeState(uncommitted: 0, unpushed: 0)),
            message(state: WorktreeState(uncommitted: 2, unpushed: 1), carried: [".env"], openTabs: 2),
        ]
        for out in cases { XCTAssertTrue(out.contains("keeps the branch"), out) }
    }

    /// `docs/brand-voice.md` bans the em-dash outright, and the test for it is a grep.
    func test_noEmDashAnywhere() {
        let out = message(
            state: WorktreeState(uncommitted: 2, unpushed: 1), carried: [".env", "node_modules"],
            openTabs: 2)
        XCTAssertFalse(out.contains("—"), out)
    }

    func test_theWholeSentence_readsAsOne() {
        XCTAssertEqual(
            message(
                state: WorktreeState(uncommitted: 3, unpushed: 2), carried: [".env", "node_modules"],
                openTabs: 2),
            "feature/zen-456 has 3 uncommitted files and 2 commits that are on no remote. "
                + "Removing it closes its 2 tabs, deletes the folder with the .env and node_modules "
                + "it carries, and keeps the branch.")
    }
}
