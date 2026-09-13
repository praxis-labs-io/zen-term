import Foundation

enum WorktreeRemovalMessage {
    struct Content: Equatable {
        let leadLines: [String]
        let rows: [WorktreeRemovalRollup.Row]
        let trailLines: [String]
    }

    /// A detached worktree's folder reads like a branch and is not one, so its short head stands in.
    static func name(_ worktree: Worktree) -> String {
        worktree.branch ?? String(worktree.head.prefix(7))
    }

    static func content(
        for worktree: Worktree, state: WorktreeState?, carried: [String], openTabs: Int
    ) -> Content {
        let name = name(worktree)
        let detached = worktree.branch == nil
        let aside = [closesAndDeletes(openTabs: openTabs, carried: carried)].compactMap { $0 }
        let stays = detached ? [] : ["The branch and its commits stay."]

        guard let state else {
            let holds = detached ? "It may hold uncommitted files and commits." : "It may hold uncommitted files."
            return Content(leadLines: ["Couldn't read \(name).", holds] + aside + stays, rows: [], trailLines: [])
        }
        guard !state.isClean else {
            return Content(leadLines: ["\(name) has nothing uncommitted."] + aside + stays, rows: [], trailLines: [])
        }

        let rows = WorktreeRemovalRollup.rows(for: state.files)
        let files = counted(state.files.count, "uncommitted file")
        let commits = counted(state.detachedCommits, "commit")
        switch (state.detachedCommits > 0, state.files.isEmpty) {
        case (true, false):
            return Content(
                leadLines: ["\(name) has \(commits) on no branch and \(files).", "Removing it loses both."],
                rows: rows, trailLines: aside)
        case (true, true):
            let loses = state.detachedCommits == 1 ? "Removing it loses that commit." : "Removing it loses them."
            return Content(leadLines: ["\(name) has \(commits) on no branch.", loses], rows: [], trailLines: aside)
        default:
            return Content(leadLines: ["\(name) has \(files)."], rows: rows, trailLines: aside + stays)
        }
    }

    private static func closesAndDeletes(openTabs: Int, carried: [String]) -> String? {
        var clauses: [String] = []
        if openTabs == 1 { clauses.append("closes 1 tab") }
        if openTabs > 1 { clauses.append("closes \(openTabs) tabs") }
        if !carried.isEmpty { clauses.append("deletes the copied \(joined(carried))") }
        guard !clauses.isEmpty else { return nil }
        let sentence = clauses.joined(separator: " and ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func joined(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        guard items.count > 2 else { return items.joined(separator: " and ") }
        return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
    }
}
