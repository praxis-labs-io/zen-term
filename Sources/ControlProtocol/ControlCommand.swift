/// The `cmd` of a request.
public enum ControlCommand: String, Codable, Sendable, CaseIterable {
    case hello
    case list
    case workspaceOpen = "workspace.open"
    case workspaceNew = "workspace.new"
    case workspaceSwitch = "workspace.switch"
    case workspaceClose = "workspace.close"
    case tabNew = "tab.new"
    case tabSelect = "tab.select"
    case tabRename = "tab.rename"
    case tabClose = "tab.close"
}
