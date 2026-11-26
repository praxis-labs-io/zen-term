enum CloseWarning {
    enum LoginTarget: String { case pane, drawer, tab }

    enum Subject: Equatable {
        case pane, drawer, float, tab, window
        case workspace(String)
        case lastPane(running: Bool), lastTab(running: Bool), lastWorkspace(running: Bool)
        case login(host: String, closing: LoginTarget)

        var title: String {
            switch self {
            case .pane: return "Close Pane"
            case .drawer: return "Close Drawer"
            case .float: return "Close Float"
            case .tab: return "Close Tab"
            case .workspace: return "Close Workspace"
            case .window, .lastPane, .lastTab, .lastWorkspace: return "Close Window"
            case .login(_, let target): return "Close \(target.rawValue.capitalized)"
            }
        }

        fileprivate var consequence: String {
            switch self {
            case .pane: return "Closing this pane will stop the process running in it"
            case .drawer: return "Closing this drawer will stop the process running in it"
            case .float: return "Closing this float will stop the process running in it"
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
            case .login(let host, let target):
                return "Closing this \(target.rawValue) will stop connecting to \(host) and close its tabs"
            }
        }
    }

    static func prompt(closing subject: Subject, naming names: [String], closingOtherWindows others: Int = 0)
        -> ConfirmPrompt
    {
        ConfirmPrompt(
            title: subject.title,
            body: .message(message(closing: subject, naming: names, closingOtherWindows: others)),
            confirmLabel: "Close", start: .onConfirm)
    }

    static func quit(tabCount: Int, windowCount: Int) -> ConfirmPrompt {
        let message: String
        if windowCount > 1 {
            message =
                "Quitting will close \(tabCount) tabs in \(windowCount) windows "
                + "and stop everything running in them."
        } else if tabCount == 1 {
            message = "Quitting will close your tab and stop everything running in it."
        } else {
            message = "Quitting will close all \(tabCount) tabs and stop everything running in them."
        }
        return ConfirmPrompt(title: "Quit ZenTerm", body: .message(message), confirmLabel: "Quit", start: .onConfirm)
    }

    static func message(closing subject: Subject, naming names: [String], closingOtherWindows others: Int = 0)
        -> String
    {
        let named = names.isEmpty ? subject.consequence + "." : subject.consequence + ", including " + list(names) + "."
        switch others {
        case 0: return named
        case 1: return named + " It also closes another window."
        default: return named + " It also closes \(others) other windows."
        }
    }

    static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
