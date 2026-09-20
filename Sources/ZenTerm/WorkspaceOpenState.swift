enum WorkspaceOpenState {
    case here
    case elsewhere
    case closed

    // `here` outranks `elsewhere`: a workspace this window already holds is switched to, never revealed.
    static func strongest(_ states: [WorkspaceOpenState]) -> WorkspaceOpenState {
        if states.contains(.here) { return .here }
        return states.contains(.elsewhere) ? .elsewhere : .closed
    }
}
