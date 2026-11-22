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
    public var lines: Int?
    public var branch: String?
    /// The commit a new branch starts from: `default` or `current`.
    public var base: String?
    public var existing: Bool?
    /// A keymap action's config name, like `toggle_sidebar`, or the name `pane.run` gives its pane.
    public var name: String?
    /// The first message `pane.run` sends its program once the program is ready.
    public var task: String?
    /// Where `pane.run` splits its pane. Absent opens a tab.
    public var split: PaneDirection?
    /// Whether `pane.run` keeps its pane open after its program exits.
    public var keep: Bool?
    /// Whether `pane.run`'s pane stays open when the pane that ran it closes. Sent as `outlive_parent`.
    public var outliveParent: Bool?

    public init(
        workspace: String? = nil, path: String? = nil, tab: String? = nil, cwd: String? = nil, cmd: String? = nil,
        title: String? = nil, focus: Bool? = nil, force: Bool? = nil, pane: ControlAddress.Pane? = nil,
        dir: PaneDirection? = nil, text: String? = nil, enter: Bool? = nil, lines: Int? = nil, branch: String? = nil,
        base: String? = nil, existing: Bool? = nil, name: String? = nil, task: String? = nil,
        split: PaneDirection? = nil, keep: Bool? = nil, outliveParent: Bool? = nil
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
        self.lines = lines
        self.branch = branch
        self.base = base
        self.existing = existing
        self.name = name
        self.task = task
        self.split = split
        self.keep = keep
        self.outliveParent = outliveParent
    }

    private enum CodingKeys: String, CodingKey {
        case workspace, path, tab, cwd, cmd, title, focus, force, pane, dir, text, enter, lines, branch, base, existing
        case name, task, split, keep
        case outliveParent = "outlive_parent"
    }
}
