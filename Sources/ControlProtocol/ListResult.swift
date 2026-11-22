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

    /// One pane or drawer, as `list` and `pane.get` report it. `drawer` is set for a drawer and absent for a pane in
    /// the tab's split tree; `process` is absent on a host's pane and when the program cannot be read. `name`,
    /// `parent` and `firstTask` are set for a pane `pane.run` opened: `parent` is the live pane that ran it.
    public struct Pane: ControlPayload, Equatable {
        public let token: Int
        public let drawer: Drawer?
        public let title: String
        public let cwd: String?
        public let busy: Bool
        public let process: Process?
        public let agent: Agent?
        public let name: String?
        public let parent: Int?
        public let firstTask: FirstTask?

        public init(
            token: Int, drawer: Drawer?, title: String, cwd: String?, busy: Bool, process: Process? = nil,
            agent: Agent?, name: String? = nil, parent: Int? = nil, firstTask: FirstTask? = nil
        ) {
            self.token = token
            self.drawer = drawer
            self.title = title
            self.cwd = cwd
            self.busy = busy
            self.process = process
            self.agent = agent
            self.name = name
            self.parent = parent
            self.firstTask = firstTask
        }

        private enum CodingKeys: String, CodingKey {
            case token, drawer, title, cwd, busy, process, agent, name, parent
            case firstTask = "first_task"
        }
    }

    /// The pane's foreground program: its process group's leader and that process's name.
    public struct Process: Codable, Equatable, Sendable {
        public let pid: Int32
        public let program: String

        public init(pid: Int32, program: String) {
            self.pid = pid
            self.program = program
        }
    }

    public enum Drawer: String, Codable, Sendable {
        case bottom, right
    }

    /// `state` is the app's reading; `status`, `kind`, `msg` and `title` are the agent's own last OSC 7501 report,
    /// absent when it sent none.
    public struct Agent: Codable, Equatable, Sendable {
        public let name: String?
        public let state: AgentState
        public let status: AgentStatus?
        public let kind: AgentNeed?
        public let msg: String?
        public let title: String?

        public init(
            name: String?, state: AgentState, status: AgentStatus? = nil, kind: AgentNeed? = nil, msg: String? = nil,
            title: String? = nil
        ) {
            self.name = name
            self.state = state
            self.status = status
            self.kind = kind
            self.msg = msg
            self.title = title
        }
    }

    public enum AgentState: String, Codable, Sendable {
        case working, waiting, idle
    }

    /// The OSC 7501 state word, as the program sent it.
    public enum AgentStatus: String, Codable, Sendable {
        case idle, working, done, blocked, error
    }

    /// What a `blocked` agent is waiting on, as the program sent it.
    public enum AgentNeed: String, Codable, Sendable {
        case permission, question, auth
    }
}
