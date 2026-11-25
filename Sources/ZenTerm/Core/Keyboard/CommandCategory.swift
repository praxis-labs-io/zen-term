enum CommandCategory: CaseIterable {
    case panes, tabs, drawers, window, tools, config, help, workspaces

    var title: String {
        switch self {
        case .panes: return "Panes"
        case .tabs: return "Tabs"
        case .drawers: return "Drawers"
        case .window: return "Window"
        case .tools: return "Tools"
        case .config: return "Config"
        case .help: return "Help"
        case .workspaces: return "Workspaces"
        }
    }

    var symbol: String {
        switch self {
        case .panes: return "rectangle.split.2x1"
        case .tabs: return "rectangle.on.rectangle"
        case .drawers: return "dock.rectangle"
        case .window: return "macwindow"
        case .tools: return "wrench.and.screwdriver"
        case .config: return "slider.horizontal.3"
        case .help: return "questionmark.circle"
        case .workspaces: return "folder"
        }
    }
}
