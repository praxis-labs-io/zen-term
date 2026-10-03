/// The worktree a command made, what its carry copied and missed, and the workspace opened on it.
public struct WorktreeResult: ControlPayload, Equatable {
    public let path: String
    public let carry: Carry
    public let window: String
    public let workspace: ListResult.Workspace

    public init(path: String, carry: Carry, window: String, workspace: ListResult.Workspace) {
        self.path = path
        self.carry = carry
        self.window = window
        self.workspace = workspace
    }

    /// `skipped` holds the entries that were there to copy and did not arrive, each with why.
    public struct Carry: Codable, Equatable, Sendable {
        public let carried: [String]
        public let skipped: [Skipped]

        public init(carried: [String], skipped: [Skipped]) {
            self.carried = carried
            self.skipped = skipped
        }
    }

    public struct Skipped: Codable, Equatable, Sendable {
        public let name: String
        public let reason: String

        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }
}
