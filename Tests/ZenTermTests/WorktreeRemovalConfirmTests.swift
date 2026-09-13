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

    private func items(
        state: WorktreeState?, branch: String? = "feature/zen-483", carried: [String] = [], openTabs: Int = 0
    ) -> [WorktreeRemovalMessage.Item] {
        WorktreeRemovalMessage.items(
            for: worktree(branch: branch), state: state, carried: carried, openTabs: openTabs)
    }

    private func lines(
        state: WorktreeState?, branch: String? = "feature/zen-483", carried: [String] = [], openTabs: Int = 0
    ) -> [String] {
        items(state: state, branch: branch, carried: carried, openTabs: openTabs).map { item in
            "\(item.mark) \(item.text.map(\.text).joined())"
        }
    }

    func test_branchWithEverything_ordersLossThenCopiesThenTabsThenWhatStays() {
        XCTAssertEqual(
            lines(state: state(files: 6), carried: [".env", "node_modules/"], openTabs: 2),
            [
                "lost Removing feature/zen-483 loses 6 uncommitted files",
                "info Deletes the copied files",
                "info Closes 2 tabs",
                "kept Branch and commits preserved",
            ])
    }

    func test_theLostFiles_andTheCopiedFiles_eachListTheirOwnRows() {
        let out = items(state: state(files: 6), carried: [".env", "node_modules/"])

        XCTAssertEqual(out[0].rows.count, 6)
        XCTAssertEqual(
            out[1].rows,
            [
                .entry(path: [.init(text: ".env", tone: .ink(.subtle))], status: []),
                .entry(path: [.init(text: "node_modules/", tone: .ink(.subtle))], status: []),
            ])
        XCTAssertEqual(out.last?.rows, [])
    }

    func test_theWorktreeName_standsOutFromTheSentence() {
        XCTAssertEqual(
            items(state: state(files: 2))[0].text,
            [
                .init(text: "Removing ", tone: .ink(.muted)), .init(text: "feature/zen-483", tone: .ink(.subtle)),
                .init(text: " loses 2 uncommitted files", tone: .ink(.muted)),
            ])
    }

    func test_counts_areSingularAtOne() {
        XCTAssertEqual(
            lines(state: state(files: 1), openTabs: 1),
            [
                "lost Removing feature/zen-483 loses 1 uncommitted file", "info Closes 1 tab",
                "kept Branch and commits preserved",
            ])
    }

    func test_cleanBranch_hasNothingLost() {
        XCTAssertEqual(
            lines(state: state()),
            ["kept feature/zen-483 has nothing uncommitted", "kept Branch and commits preserved"])
    }

    func test_unreadable_warnsInOneLine_andNeverSaysItIsClean() {
        XCTAssertEqual(
            lines(state: nil),
            [
                "warning Couldn't read feature/zen-483 to check for uncommitted files",
                "kept Branch and commits preserved",
            ])
    }

    func test_detachedWithCommitsAndFiles_losesBoth_andKeepsNothing() {
        let out = items(state: state(files: 3, commits: 2), branch: nil, openTabs: 1)

        XCTAssertEqual(
            out.map { "\($0.mark) \($0.text.map(\.text).joined())" },
            ["lost Removing 0123456 loses 2 commits and 3 uncommitted files", "info Closes 1 tab"])
        XCTAssertEqual(out[0].rows.count, 3)
    }

    func test_detachedWithCommitsOnly_hasNoList() {
        let out = items(state: state(commits: 1), branch: nil)

        XCTAssertEqual(out.map(\.mark), [.lost])
        XCTAssertEqual(out[0].text.map(\.text).joined(), "Removing 0123456 loses 1 commit")
        XCTAssertEqual(out[0].rows, [])
    }

    func test_detachedWithFilesOnly() {
        XCTAssertEqual(lines(state: state(files: 2), branch: nil), ["lost Removing 0123456 loses 2 uncommitted files"])
    }

    func test_detachedCleanAndUnreadable_neverMentionABranch() {
        XCTAssertEqual(lines(state: state(), branch: nil), ["kept 0123456 has nothing uncommitted"])
        XCTAssertEqual(
            lines(state: nil, branch: nil), ["warning Couldn't read 0123456 to check for uncommitted files or commits"])
    }

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

    func test_noEmDashAnywhere() {
        let cases = [
            lines(state: nil), lines(state: state(files: 3, commits: 2), branch: nil, carried: [".env"], openTabs: 2),
            lines(state: state(), carried: [".env", "node_modules/"], openTabs: 1),
        ]
        for text in cases.flatMap({ $0 }) {
            XCTAssertFalse(text.contains("—"), text)
        }
    }
}
