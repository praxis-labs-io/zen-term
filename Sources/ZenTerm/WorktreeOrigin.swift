struct WorktreeOrigin: Equatable {
    let parent: Workspace
    let name: String

    init(parent: Workspace, worktree: Worktree) {
        self.parent = parent
        name = worktree.branch ?? String(worktree.head.prefix(7))
    }
}
