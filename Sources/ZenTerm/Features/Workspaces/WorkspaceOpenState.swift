enum WorkspaceOpenState {
    case here
    case elsewhere
    case closed

    static func strongest(_ states: [WorkspaceOpenState]) -> WorkspaceOpenState {
        if states.contains(.here) { return .here }
        return states.contains(.elsewhere) ? .elsewhere : .closed
    }
}
