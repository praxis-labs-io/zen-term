import Foundation

struct WorktreeOrigin: Equatable {
    static let removedDetail = "removed"

    let parent: Workspace
    let name: String
    let path: URL

    init(parent: Workspace, worktree: Worktree) {
        self.parent = parent
        name = worktree.branch ?? String(worktree.head.prefix(7))
        path = worktree.path.standardizedFileURL
    }
}
