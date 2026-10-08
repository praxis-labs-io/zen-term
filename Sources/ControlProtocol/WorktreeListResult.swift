/// The linked worktrees of a workspace's repo, its main checkout left out.
public struct WorktreeListResult: ControlPayload, Equatable {
    public let worktrees: [Worktree]

    public init(worktrees: [Worktree]) { self.worktrees = worktrees }

    /// `branch` is absent for a detached checkout.
    public struct Worktree: Codable, Equatable, Sendable {
        public let path: String
        public let branch: String?
        public let head: String
        public let locked: Bool

        public init(path: String, branch: String?, head: String, locked: Bool) {
            self.path = path
            self.branch = branch
            self.head = head
            self.locked = locked
        }
    }
}
