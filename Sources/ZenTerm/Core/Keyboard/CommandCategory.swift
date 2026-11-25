enum CommandCategory: CaseIterable {
    case workspaces, tabs, panes, window, tools, app

    var title: String {
        switch self {
        case .workspaces: return "Workspaces"
        case .tabs: return "Tabs"
        case .panes: return "Panes"
        case .window: return "Window"
        case .tools: return "Tools"
        case .app: return "App"
        }
    }

    var symbol: String {
        switch self {
        case .workspaces: return "folder"
        case .tabs: return "rectangle.on.rectangle"
        case .panes: return "rectangle.split.2x1"
        case .window: return "macwindow"
        case .tools: return "wrench.and.screwdriver"
        case .app: return "gearshape"
        }
    }
}
