import Foundation

struct RunningWorkspace: Equatable {
    let window: Int
    // Nil for the ghost row naming the closed parent of an open worktree.
    let id: WorkspaceID?
    let name: String
    let folder: URL
    let isWorktree: Bool
    // The worktree's name once it was removed outside ZenTerm while this stays open.
    let removedWorktree: String?
}
