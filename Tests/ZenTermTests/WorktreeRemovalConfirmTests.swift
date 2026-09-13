import XCTest

@testable import ZenTerm

final class WorktreeRemovalConfirmTests: XCTestCase {
    private func worktree(branch: String? = "feature/zen-483") -> Worktree {
        Worktree(
            path: URL(fileURLWithPath: "/tmp/wt"), branch: branch,
            head: "0123456789abcdef", isLocked: false)
    }

    private func state(files: Int = 0, commits: Int = 0) -> WorktreeState {
        WorktreeState(
            files: (0..<files).map { WorktreeFileChange(path: "file\($0).txt", categories: [.modified]) },
            detachedCommits: commits)
    }

    private func content(
        state: WorktreeState?, branch: String? = "feature/zen-483", carried: [String] = [], openTabs: Int = 0
    ) -> WorktreeRemovalMessage.Content {
        WorktreeRemovalMessage.content(
            for: worktree(branch: branch), state: state, carried: carried, openTabs: openTabs)
    }

    // MARK: on a branch

    func test_branchWithFiles_listsThemAndSaysTheBranchStays() {
        let out = content(state: state(files: 6), carried: [".env"], openTabs: 2)

        XCTAssertEqual(out.leadLines, ["Removing feature/zen-483 loses 6 uncommitted files."])
        XCTAssertEqual(out.rows.count, 6)
        XCTAssertEqual(
            out.trailLines, ["Closes 2 tabs and deletes the copied .env.", "The branch and its commits stay."])
    }

    func test_oneFile_isSingular() {
        XCTAssertEqual(
            content(state: state(files: 1)).leadLines, ["Removing feature/zen-483 loses 1 uncommitted file."])
    }

    func test_cleanBranch_isOneBlockWithNoList() {
        let out = content(state: state(), openTabs: 1)

        XCTAssertEqual(
            out.leadLines,
            ["feature/zen-483 has nothing uncommitted.", "Closes 1 tab.", "The branch and its commits stay."])
        XCTAssertEqual(out.rows, [])
        XCTAssertEqual(out.trailLines, [])
    }

    /// Nil is not clean: this is the one message that must never tell someone a tree holds nothing.
    func test_unreadable_neverSaysItIsClean() {
        let out = content(state: nil)

        XCTAssertEqual(
            out.leadLines,
            ["Couldn't read feature/zen-483.", "It may hold uncommitted files.", "The branch and its commits stay."])
        XCTAssertEqual(out.rows, [])
    }

    // MARK: detached

    func test_detachedWithCommitsAndFiles_losesBoth() {
        let out = content(state: state(files: 3, commits: 2), branch: nil, openTabs: 1)

        XCTAssertEqual(
            out.leadLines, ["Removing 0123456 loses 2 commits on no branch and 3 uncommitted files."])
        XCTAssertEqual(out.rows.count, 3)
        XCTAssertEqual(out.trailLines, ["Closes 1 tab."])
    }

    func test_detachedWithCommitsOnly_hasNoList() {
        XCTAssertEqual(
            content(state: state(commits: 2), branch: nil).leadLines, ["Removing 0123456 loses 2 commits on no branch."]
        )
        let single = content(state: state(commits: 1), branch: nil)
        XCTAssertEqual(single.leadLines, ["Removing 0123456 loses 1 commit on no branch."])
        XCTAssertEqual(single.rows, [])
    }

    func test_detachedWithFilesOnly_neverSaysABranchStays() {
        let out = content(state: state(files: 2), branch: nil)

        XCTAssertEqual(out.leadLines, ["Removing 0123456 loses 2 uncommitted files."])
        XCTAssertEqual(out.trailLines, [])
    }

    func test_detachedCleanAndUnreadable_neverMentionABranch() {
        XCTAssertEqual(content(state: state(), branch: nil).leadLines, ["0123456 has nothing uncommitted."])
        XCTAssertEqual(
            content(state: nil, branch: nil).leadLines,
            ["Couldn't read 0123456.", "It may hold uncommitted files and commits."])
    }

    // MARK: what else goes

    func test_tabsAndCopiedFiles_shareOneSentence() {
        func aside(carried: [String], openTabs: Int) -> String? {
            content(state: state(), branch: nil, carried: carried, openTabs: openTabs).leadLines.dropFirst().first
        }

        XCTAssertNil(aside(carried: [], openTabs: 0))
        XCTAssertEqual(aside(carried: [], openTabs: 4), "Closes 4 tabs.")
        XCTAssertEqual(
            aside(carried: [".env", "node_modules"], openTabs: 0), "Deletes the copied .env and node_modules.")
        XCTAssertEqual(
            aside(carried: [".env", "node_modules", ".venv"], openTabs: 1),
            "Closes 1 tab and deletes the copied .env, node_modules, and .venv.")
    }

    // MARK: rows

    func test_aFileRow_splitsItsFolderFromItsName_andCarriesEveryGlyph() {
        let row = WorktreeRemovalRollup.Row.file(
            WorktreeFileChange(path: "Sources/ZenTerm/App.swift", categories: [.staged, .modified]))

        XCTAssertEqual(
            row.listRow,
            .entry(
                path: [
                    .init(text: "Sources/ZenTerm/", tone: .ink(.muted)), .init(text: "App.swift", tone: .ink(.subtle)),
                ],
                status: [[.init(text: "+", tone: .role(\.positive)), .init(text: "~", tone: .role(\.warning))]]))
    }

    func test_aFolderRow_countsEachStatusSeparately() {
        let row = WorktreeRemovalRollup.Row.folder(
            path: "build/cache",
            files: [
                WorktreeFileChange(path: "build/cache/a", categories: [.untracked]),
                WorktreeFileChange(path: "build/cache/b", categories: [.untracked]),
                WorktreeFileChange(path: "build/cache/c", categories: [.staged, .modified]),
            ])

        XCTAssertEqual(
            row.listRow,
            .entry(
                path: [.init(text: "build/cache/", tone: .ink(.subtle))],
                status: [
                    [.init(text: "+1", tone: .role(\.positive))], [.init(text: "~1", tone: .role(\.warning))],
                    [.init(text: "?2", tone: .role(\.attention))],
                ]))
    }

    func test_theSpillRow_countsHiddenFiles() {
        XCTAssertEqual(WorktreeRemovalRollup.Row.more(hiddenFiles: 35).listRow, .note("and 35 more"))
    }

    /// `docs/brand-voice.md` bans the em-dash outright, and the test for it is a grep.
    func test_noEmDashAnywhere() {
        let cases = [
            content(state: nil),
            content(state: state(files: 3, commits: 2), branch: nil, carried: [".env"], openTabs: 2),
            content(state: state(), carried: [".env", "node_modules"], openTabs: 1),
        ]
        for out in cases {
            let text = (out.leadLines + out.trailLines).joined(separator: " ")
            XCTAssertFalse(text.contains("—"), text)
        }
    }
}
