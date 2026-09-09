import Foundation

/// Which configured workspace shows a repo's worktrees, and which of them it shows. Two lists read
/// this: the ⌘P picker and Settings → Workspaces.
enum WorktreeGrouping {
    /// Common dir to the workspace that shows its worktrees, decided from config order.
    ///
    /// Two workspaces can be checkouts of one repo, and `worktree list` answers the same set for
    /// both. Deciding this from a filtered or re-sorted list would let a query move a worktree to a
    /// different parent and so open it with a different recipe. An empty listing never claims: a
    /// workspace inside a repo but not at its root resolves a common dir and lists nothing, and
    /// claiming there would hide the real checkout's worktrees.
    static func owners(among workspaces: [Workspace], listings: [URL: WorktreeListing]) -> [URL: URL] {
        var owners: [URL: URL] = [:]
        for workspace in workspaces {
            let path = workspace.path.standardizedFileURL
            guard let listing = listings[path], !listing.worktrees.isEmpty else { continue }
            let key = listing.commonDir ?? path
            if owners[key] == nil { owners[key] = path }
        }
        return owners
    }

    /// The worktrees to render under `workspace`, empty when another workspace owns the repo. A
    /// worktree the user has configured as a workspace of its own is dropped rather than repeated
    /// as a child of one.
    static func worktrees(
        of workspace: Workspace, listings: [URL: WorktreeListing], owners: [URL: URL],
        configured: Set<URL>
    ) -> [Worktree] {
        let path = workspace.path.standardizedFileURL
        guard let listing = listings[path], owners[listing.commonDir ?? path] == path else {
            return []
        }
        return listing.worktrees.filter { !configured.contains($0.path.standardizedFileURL) }
    }
}
