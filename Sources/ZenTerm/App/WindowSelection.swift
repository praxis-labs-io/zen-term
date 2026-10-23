@MainActor
enum WindowSelection {
    case workspace(WorkspaceController)
    case host(SSHHostID)

    var workspace: WorkspaceController? {
        guard case .workspace(let workspace) = self else { return nil }
        return workspace
    }

    var host: SSHHostID? {
        switch self {
        case .workspace(let workspace): return workspace.host
        case .host(let host): return host
        }
    }
}
