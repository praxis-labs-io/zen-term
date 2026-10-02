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

    public init(
        workspace: String? = nil, path: String? = nil, tab: String? = nil, cwd: String? = nil, cmd: String? = nil,
        title: String? = nil, focus: Bool? = nil, force: Bool? = nil
    ) {
        self.workspace = workspace
        self.path = path
        self.tab = tab
        self.cwd = cwd
        self.cmd = cmd
        self.title = title
        self.focus = focus
        self.force = force
    }
}
