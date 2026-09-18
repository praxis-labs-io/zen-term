/// The confirm copy for a close, naming what it ends that nothing on screen shows.
enum CloseWarning {
    enum Subject {
        case pane, drawer, tab, window

        var title: String {
            switch self {
            case .pane: return "Close Pane"
            case .drawer: return "Close Drawer"
            case .tab: return "Close Tab"
            case .window: return "Close Window"
            }
        }

        fileprivate var consequence: String {
            switch self {
            case .pane: return "Closing this pane will stop the process running in it"
            case .drawer: return "Closing this drawer will stop the process running in it"
            case .tab: return "Closing this tab will stop everything running in it"
            case .window: return "Closing this window will stop everything running in it"
            }
        }
    }

    /// The consequence on its own, or with the names appended as an `including` clause.
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
