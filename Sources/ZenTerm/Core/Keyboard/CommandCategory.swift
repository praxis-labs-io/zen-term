enum CommandCategory: CaseIterable {
    case workspaces, tabs, panes, terminal, window, tools, app

    var title: String {
        switch self {
        case .workspaces: return "Workspaces"
        case .tabs: return "Tabs"
        case .panes: return "Panes"
        case .terminal: return "Terminal"
        case .window: return "Window"
        case .tools: return "Tools"
        case .app: return "App"
        }
    }

    var icon: ProcessIcon {
        switch self {
        case .workspaces: return .workspace
        case .tabs: return .tab
        case .panes: return .pane
        case .terminal: return .terminal
        case .window: return .window
        case .tools: return .tool
        case .app: return .app
        }
    }
}
