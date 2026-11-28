/// A request's `args`. Each command reads the fields it takes and ignores the rest.
public struct ControlArgs: Codable, Equatable, Sendable {
    /// A workspace address: its folder as an absolute path, `ssh:<host>`, or its title.
    public var workspace: String?
    public var path: String?
    /// A tab address, `w<window>.t<tab>`.
    public var tab: String?
    public var cwd: String?
    public var cmd: String?
    public var title: String?
    public var focus: Bool?
    public var force: Bool?
    public var pane: ControlAddress.Pane?
    public var dir: PaneDirection?
    public var text: String?
    public var enter: Bool?
    /// `PaneKey` names, pressed in order.
    public var keys: [String]?
    public var lines: Int?
    public var since: PaneReadSince?
    public var branch: String?
    /// The commit a new branch starts from: `default` or `current`.
    public var base: String?
    public var existing: Bool?
    public var open: Bool?
    /// A keymap action's config name, like `toggle_sidebar`, or the name `pane.run` gives its pane.
    public var name: String?
    /// The first message `pane.run` sends its program once the program is ready.
    public var task: String?
    /// Where `pane.run` splits its pane. Absent opens a float or a tab, as `float` says.
    public var split: PaneDirection?
    /// Whether `pane.run` opens a hidden float pane (true) or a tab (false). Absent: a float when the caller runs an
    /// agent and its pane does not outlive it, else a tab.
    public var float: Bool?
    /// Whether `pane.run` keeps its pane open after its program exits.
    public var keep: Bool?
    /// Whether `pane.run`'s pane stays open when the pane that ran it closes. Sent as `outlive_parent`.
    public var outliveParent: Bool?
    /// Whether `pane.run` first closes the caller's pane that has its `name`.
    public var replace: Bool?
    /// Text `pane.wait` answers on once it appears in the pane's output.
    public var output: String?
    /// Seconds `pane.wait`, or a `pane.send` that waits, holds before it answers `timeout`.
    public var timeout: Int?
    /// `pane.send` answers as `pane.wait` on its target once the text is in.
    public var wait: Bool?
    /// Which of the caller's children `pane.wait` waits on, in place of a pane.
    public var children: WaitChildren?
    /// The token a host login's ssh was started with, which `ssh.askpass` must carry.
    public var token: String?
    /// The question ssh asks, verbatim.
    public var prompt: String?
    /// The pid of the ssh that asks. Sent as `ssh_pid`.
    public var sshPID: Int?
    /// Seconds an `awake.on` hold lasts. Absent holds until `awake.off` or the pane exits.
    public var duration: Int?

    public init(
        workspace: String? = nil, path: String? = nil, tab: String? = nil, cwd: String? = nil, cmd: String? = nil,
        title: String? = nil, focus: Bool? = nil, force: Bool? = nil, pane: ControlAddress.Pane? = nil,
        dir: PaneDirection? = nil, text: String? = nil, enter: Bool? = nil, keys: [String]? = nil, lines: Int? = nil,
        since: PaneReadSince? = nil,
        branch: String? = nil, base: String? = nil, existing: Bool? = nil, open: Bool? = nil, name: String? = nil,
        output: String? = nil, timeout: Int? = nil, task: String? = nil, split: PaneDirection? = nil,
        float: Bool? = nil, keep: Bool? = nil, outliveParent: Bool? = nil, replace: Bool? = nil,
        wait: Bool? = nil,
        children: WaitChildren? = nil, token: String? = nil, prompt: String? = nil, sshPID: Int? = nil,
        duration: Int? = nil
    ) {
        self.workspace = workspace
        self.path = path
        self.tab = tab
        self.cwd = cwd
        self.cmd = cmd
        self.title = title
        self.focus = focus
        self.force = force
        self.pane = pane
        self.dir = dir
        self.text = text
        self.enter = enter
        self.keys = keys
        self.lines = lines
        self.since = since
        self.branch = branch
        self.base = base
        self.existing = existing
        self.open = open
        self.name = name
        self.output = output
        self.timeout = timeout
        self.wait = wait
        self.task = task
        self.split = split
        self.float = float
        self.keep = keep
        self.outliveParent = outliveParent
        self.replace = replace
        self.children = children
        self.token = token
        self.prompt = prompt
        self.sshPID = sshPID
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case workspace, path, tab, cwd, cmd, title, focus, force, pane, dir, text, enter, keys, lines, since, branch
        case base, existing, open, name, output, timeout, task, split, float, keep, replace, wait, children
        case token, prompt, duration
        case outliveParent = "outlive_parent"
        case sshPID = "ssh_pid"
    }
}
