/// The workspace a command opened, switched to or found, and the window that holds it.
public struct WorkspaceResult: ControlPayload, Equatable {
    public let window: String
    public let workspace: ListResult.Workspace

    public init(window: String, workspace: ListResult.Workspace) {
        self.window = window
        self.workspace = workspace
    }
}
