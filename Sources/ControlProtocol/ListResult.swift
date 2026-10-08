/// Every window, its workspaces in sidebar order with SSH hosts' last, their tabs in tab order, and each tab's panes then drawers.
public struct ListResult: ControlPayload, Equatable {
    public let windows: [Window]

    public init(windows: [Window]) { self.windows = windows }

    public struct Window: Codable, Equatable, Sendable {
        public let id: String
        public let key: Bool
        public let workspaces: [Workspace]

        public init(id: String, key: Bool, workspaces: [Workspace]) {
            self.id = id
            self.key = key
            self.workspaces = workspaces
        }
    }

    /// `folder` is absent and `host` is set for an SSH host's workspace.
    public struct Workspace: Codable, Equatable, Sendable {
        public let title: String
        public let folder: String?
        public let host: Host?
        public let configured: Bool
        public let worktree: Worktree?
        public let active: Bool
        public let tabs: [Tab]

        public init(
            title: String, folder: String?, host: Host? = nil, configured: Bool, worktree: Worktree?, active: Bool,
            tabs: [Tab]
        ) {
            self.title = title
            self.folder = folder
            self.host = host
            self.configured = configured
            self.worktree = worktree
            self.active = active
            self.tabs = tabs
        }
    }

    /// The SSH host a workspace runs on, by its alias, and whether its connection is up yet.
    public struct Host: Codable, Equatable, Sendable {
        public let alias: String
        public let state: HostState

        public init(alias: String, state: HostState) {
            self.alias = alias
            self.state = state
        }
    }

    public enum HostState: String, Codable, Sendable {
        case connecting, connected
    }

    /// The worktree a workspace was opened from: its name and the folder of the workspace it belongs to.
    public struct Worktree: Codable, Equatable, Sendable {
        public let name: String
        public let parent: String

        public init(name: String, parent: String) {
            self.name = name
            self.parent = parent
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let active: Bool
        public let panes: [Pane]

        public init(id: String, title: String, active: Bool, panes: [Pane]) {
            self.id = id
            self.title = title
            self.active = active
            self.panes = panes
        }
    }

    /// `drawer` is set for a drawer and absent for a pane in the tab's split tree.
    public struct Pane: Codable, Equatable, Sendable {
        public let token: Int
        public let drawer: Drawer?
        public let title: String
        public let cwd: String?
        public let busy: Bool
        public let agent: Agent?

        public init(token: Int, drawer: Drawer?, title: String, cwd: String?, busy: Bool, agent: Agent?) {
            self.token = token
            self.drawer = drawer
            self.title = title
            self.cwd = cwd
            self.busy = busy
            self.agent = agent
        }
    }

    public enum Drawer: String, Codable, Sendable {
        case bottom, right
    }

    public struct Agent: Codable, Equatable, Sendable {
        public let name: String?
        public let state: AgentState

        public init(name: String?, state: AgentState) {
            self.name = name
            self.state = state
        }
    }

    public enum AgentState: String, Codable, Sendable {
        case working, waiting, idle
    }
}
