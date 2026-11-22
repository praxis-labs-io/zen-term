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
    /// A pane or drawer token.
    public var pane: Int?
    public var dir: PaneDirection?
    public var text: String?
    public var enter: Bool?
    /// `PaneKey` names, pressed in order.
    public var keys: [String]?
    public var lines: Int?
    public var branch: String?
    /// The commit a new branch starts from: `default` or `current`.
    public var base: String?
    public var existing: Bool?
    public var open: Bool?
    /// A keymap action's config name, like `toggle_sidebar`.
    public var name: String?
    /// Text `pane.wait` answers on once it appears in the pane's output.
    public var output: String?
    /// Seconds `pane.wait` holds before it answers `timeout`.
    public var timeout: Int?

    public init(
        workspace: String? = nil, path: String? = nil, tab: String? = nil, cwd: String? = nil, cmd: String? = nil,
        title: String? = nil, focus: Bool? = nil, force: Bool? = nil, pane: Int? = nil, dir: PaneDirection? = nil,
        text: String? = nil, enter: Bool? = nil, keys: [String]? = nil, lines: Int? = nil, branch: String? = nil,
        base: String? = nil, existing: Bool? = nil, open: Bool? = nil, name: String? = nil, output: String? = nil,
        timeout: Int? = nil
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
        self.branch = branch
        self.base = base
        self.existing = existing
        self.open = open
        self.name = name
        self.output = output
        self.timeout = timeout
    }
}
