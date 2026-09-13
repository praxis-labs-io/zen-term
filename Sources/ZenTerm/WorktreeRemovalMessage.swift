import Foundation

enum WorktreeRemovalMessage {
    typealias Item = ConfirmCardChecklist.Item

    static func name(_ worktree: Worktree) -> String {
        worktree.branch ?? String(worktree.head.prefix(7))
    }

    static func items(
        for worktree: Worktree, state: WorktreeState?, carried: [String], openTabs: Int
    ) -> [Item] {
        let name = name(worktree)
        let detached = worktree.branch == nil
        var items = [whatItHolds(name: name, detached: detached, state: state)]
        if !carried.isEmpty {
            items.append(Item(mark: .info, text: plain("Deletes the copied files"), rows: copiedRows(carried)))
        }
        if openTabs > 0 {
            items.append(Item(mark: .info, text: plain("Closes \(counted(openTabs, "tab"))"), rows: []))
        }
        if !detached, (state?.lostCommits ?? 0) == 0 {
            items.append(Item(mark: .kept, text: plain("Branch and commits preserved"), rows: []))
        }
        return items
    }

    private static func whatItHolds(name: String, detached: Bool, state: WorktreeState?) -> Item {
        guard let state else {
            let checked = detached ? "uncommitted files or commits" : "uncommitted files"
            return Item(mark: .warning, text: naming(name, "Couldn't read ", " to check for \(checked)"), rows: [])
        }
        let files = counted(state.files.count, "uncommitted file")
        let commits = counted(state.lostCommits, "commit")
        let rows = WorktreeRemovalRollup.rows(for: state.files).map(\.listRow)
        switch (state.lostCommits > 0, state.files.isEmpty) {
        case (true, false):
            return Item(mark: .lost, text: naming(name, "Removing ", " loses \(commits) and \(files)"), rows: rows)
        case (true, true):
            return Item(mark: .lost, text: naming(name, "Removing ", " loses \(commits)"), rows: [])
        case (false, false):
            return Item(mark: .lost, text: naming(name, "Removing ", " loses \(files)"), rows: rows)
        case (false, true):
            return Item(mark: .kept, text: naming(name, "", " has nothing uncommitted"), rows: [])
        }
    }

    private static func copiedRows(_ carried: [String]) -> [ConfirmCardList.Row] {
        let limit = WorktreeRemovalRollup.rowLimit
        let shown = carried.count > limit ? Array(carried.prefix(limit - 1)) : carried
        let rows = shown.map { ConfirmCardList.Row.entry(path: [.init(text: $0, tone: .ink(.subtle))], status: []) }
        return carried.count > limit ? rows + [.note("and \(carried.count - shown.count) more")] : rows
    }

    private static func naming(_ name: String, _ before: String, _ after: String) -> [ConfirmCardList.Run] {
        [
            .init(text: before, tone: .ink(.muted)), .init(text: name, tone: .ink(.subtle)),
            .init(text: after, tone: .ink(.muted)),
        ].filter { !$0.text.isEmpty }
    }

    private static func plain(_ text: String) -> [ConfirmCardList.Run] {
        [.init(text: text, tone: .ink(.muted))]
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
