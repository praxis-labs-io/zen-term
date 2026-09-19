enum CloseWarning {
    enum Subject: Equatable {
        case pane, drawer, tab, window
        case workspace(String)
        case lastPane(running: Bool), lastTab(running: Bool), lastWorkspace(running: Bool)

        var title: String {
            switch self {
            case .pane: return "Close Pane"
            case .drawer: return "Close Drawer"
            case .tab: return "Close Tab"
            case .workspace: return "Close Workspace"
            case .window, .lastPane, .lastTab, .lastWorkspace: return "Close Window"
            }
        }

        fileprivate var consequence: String {
            switch self {
            case .pane: return "Closing this pane will stop the process running in it"
            case .drawer: return "Closing this drawer will stop the process running in it"
            case .tab: return "Closing this tab will stop everything running in it"
            case .window: return "Closing this window will stop everything running in it"
            case .workspace(let name): return "Closing \(name) will stop everything running in it"
            case .lastPane(let running):
                return "Closing this pane will close the window"
                    + (running ? " and stop everything running in it" : "")
            case .lastTab(let running):
                return "Closing this tab will close the window"
                    + (running ? " and stop everything running in it" : "")
            case .lastWorkspace(let running):
                return "Closing this workspace will close the window"
                    + (running ? " and stop everything running in it" : "")
            }
        }
    }

    static func message(closing subject: Subject, naming names: [String]) -> String {
        guard !names.isEmpty else { return subject.consequence + "." }
        return subject.consequence + ", including " + list(names) + "."
    }

    static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
