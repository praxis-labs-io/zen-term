@MainActor
enum WindowSelection {
    case workspace(WorkspaceController)
    case host(SSHHostID)

    var workspace: WorkspaceController? {
        guard case .workspace(let workspace) = self else { return nil }
        return workspace
    }
}
