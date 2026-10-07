/// The workspace a command opened, switched to or found, and the window that holds it. For an SSH host with no
/// session, `workspace` is absent and `connect` names the host whose Connect screen the window shows.
public struct WorkspaceResult: ControlPayload, Equatable {
    public let window: String
    public let workspace: ListResult.Workspace?
    public let connect: String?

    public init(window: String, workspace: ListResult.Workspace?, connect: String? = nil) {
        self.window = window
        self.workspace = workspace
        self.connect = connect
    }
}
