import ControlProtocol

/// `zen list --pretty`: one indented line per window, workspace, tab and pane.
enum ListTree {
    private static let gap = "  "

    static func text(_ list: ListResult, caller: Int? = nil) -> String {
        list.windows.flatMap { lines(window: $0, caller: caller) }.joined(separator: "\n")
    }

    private static func lines(window: ListResult.Window, caller: Int?) -> [String] {
        [line(0, [window.id, window.key ? "key" : nil])]
            + window.workspaces.flatMap { lines(workspace: $0, caller: caller) }
    }

    private static func lines(workspace: ListResult.Workspace, caller: Int?) -> [String] {
        let origin = workspace.worktree.map { "worktree \($0.name) of \($0.parent)" }
        let host = workspace.host.map { "\(ControlAddress.hostPrefix)\($0.alias) \($0.state.rawValue)" }
        let head = line(
            1,
            [
                workspace.title, workspace.folder, host, workspace.active ? "active" : nil,
                workspace.configured ? "configured" : nil, origin,
            ])
        return [head] + workspace.tabs.flatMap { lines(tab: $0, caller: caller) }
    }

    private static func lines(tab: ListResult.Tab, caller: Int?) -> [String] {
        [line(2, [tab.id, tab.title, tab.active ? "active" : nil])] + tab.panes.map { line(pane: $0, caller: caller) }
    }

    private static func line(pane: ListResult.Pane, caller: Int?) -> String {
        let agent = pane.agent.map { "\($0.name ?? "agent") \($0.state.rawValue)" }
        return line(
            3,
            [
                String(pane.token), pane.token == caller ? "you" : nil, pane.drawer.map { "\($0.rawValue) drawer" },
                pane.float == true ? "float" : nil, pane.name.map { "named \($0)" }, pane.title,
                pane.cwd, pane.busy ? "busy" : nil, agent,
            ])
    }

    private static func line(_ depth: Int, _ fields: [String?]) -> String {
        String(repeating: gap, count: depth) + fields.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: gap)
    }
}
