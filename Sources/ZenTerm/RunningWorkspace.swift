import Foundation

struct RunningWorkspace: Equatable {
    let window: Int
    // Nil for the ghost row naming the closed parent of an open worktree.
    let id: WorkspaceID?
    let name: String
    let folder: URL
    let isWorktree: Bool
}
