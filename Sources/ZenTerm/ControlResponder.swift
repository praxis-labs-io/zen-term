import ControlProtocol
import Foundation
import TabKit

@MainActor
struct ControlResponder {
    let windows: () -> [WindowController]
    let keyWindow: () -> WindowController?
    var bringForward: (WindowController) -> Void = { _ in }
    var isInFront: (WindowController) -> Bool = { _ in false }
    var loadWorkspaces: (@escaping ([Workspace]) -> Void) -> Void = { ConfigLoader.loadWorkspaces(completion: $0) }
    var worktreeRemovals = WorktreeRemovalTracker()
    var runAction: (KeyInterceptor.ReservedChord) -> Void = { _ in }

    func respond(to request: ControlRequest, reply: @escaping (ControlReply) -> Void) {
        switch request.cmd {
        case .hello: reply(.success(HelloResult(app: AppVersion.current)))
        case .list: reply(.success(ListResult(windows: windows().map { $0.listing() })))
        case .workspaceOpen: openWorkspace(request, reply: reply)
        case .workspaceNew: reply(newWorkspace(request))
        case .workspaceSwitch: reply(switchWorkspace(request))
        case .workspaceClose: reply(closeWorkspace(request))
        case .tabNew: reply(newTab(request))
        case .tabSelect: reply(selectTab(request))
        case .tabRename: reply(renameTab(request))
        case .tabClose: reply(closeTab(request))
        case .paneSplit: reply(splitPane(request))
        case .paneFocus: reply(focusPane(request))
        case .paneClose: reply(closePane(request))
        case .paneSend: reply(sendToPane(request))
        case .paneRead: reply(readPane(request))
        case .worktreeList: listWorktrees(request, reply: reply)
        case .worktreeCreate: createWorktree(request, reply: reply)
        case .worktreeRemove: removeWorktree(request, reply: reply)
        case .action: reply(performAction(request))
        }
    }

    func locate(pane token: Int) -> (window: WindowController, tab: TabID, pane: PaneHandle)? {
        for window in windows() {
            if let (tab, pane) = window.pane(token: token) { return (window, tab, pane) }
        }
        return nil
    }

    private func openWorkspace(_ request: ControlRequest, reply: @escaping (ControlReply) -> Void) {
        guard let address = request.args.workspace else {
            return reply(.failure(ControlError(.badRequest, "workspace.open needs a workspace.")))
        }
        switch findOpenWorkspace(address) {
        case .success(let place): return reply(.success(present(place, focus: request.args.focus)))
        case .failure(let error) where error.code != .notFound: return reply(.failure(error))
        case .failure(let error):
            if case .host(let alias) = ControlAddress.Workspace(address) {
                return reply(showConnect(alias, unconnected: error, for: request))
            }
        }
        loadWorkspaces { entries in
            reply(openConfigured(address, from: entries, for: request))
        }
    }

    private func showConnect(_ alias: String, unconnected: ControlError, for request: ControlRequest) -> ControlReply {
        guard GeneralConfig.current.sshHostAliases.contains(alias) else { return .failure(unconnected) }
        let address = ControlAddress.hostPrefix + alias
        guard request.args.focus == true else {
            return .failure(
                ControlError(.refused, "\(address) is not connected. Add --focus to show its Connect screen."))
        }
        guard let window = callerWindow(request) else {
            return .failure(ControlError(.notFound, "No ZenTerm window is open."))
        }
        window.activate(SSHHostID(alias: alias))
        raise(window)
        return .success(WorkspaceResult(window: ControlAddress.window(window.windowID), workspace: nil, connect: alias))
    }

    private func openConfigured(_ address: String, from entries: [Workspace], for request: ControlRequest)
        -> ControlReply
    {
        if case .success(let place) = findOpenWorkspace(address) {
            return .success(present(place, focus: request.args.focus))
        }
        let matches = entries.filter { Self.names($0, address) }
        guard matches.count < 2 else {
            return .failure(ControlError(.ambiguous, "\(address) names \(matches.count) configured workspaces."))
        }
        guard let entry = matches.first else {
            return .failure(ControlError(.notFound, "No workspace is open or configured at \(address)."))
        }
        return caller(request).map { context in
            let place = WorkspacePlace(window: context.window, id: context.window.openConfiguredWorkspace(entry))
            return present(place, focus: request.args.focus)
        }
    }

    static func names(_ entry: Workspace, _ address: String) -> Bool {
        switch ControlAddress.Workspace(address) {
        case .folder(let path): return entry.path.standardizedFileURL.path == Self.standardized(path)
        case .host: return false
        case .title(let title): return entry.title == title
        }
    }

    static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    private func newWorkspace(_ request: ControlRequest) -> ControlReply {
        let folder: URL
        switch request.args.path {
        case nil: folder = ShellLaunch.defaultCWD
        case let path? where path.hasPrefix("/"): folder = URL(fileURLWithPath: path, isDirectory: true)
        case let path?: return .failure(ControlError(.badRequest, "\(path) is not an absolute path."))
        }
        return caller(request).map { context in
            let id = context.window.openUnconfiguredWorkspace(at: folder)
            return present(WorkspacePlace(window: context.window, id: id), focus: request.args.focus)
        }
    }

    private func switchWorkspace(_ request: ControlRequest) -> ControlReply {
        workspace(request.args.workspace, for: request).map { place in
            place.window.activateWorkspace(place.id)
            raise(place.window)
            return NoPayload()
        }
    }

    private func closeWorkspace(_ request: ControlRequest) -> ControlReply {
        workspace(request.args.workspace, for: request).flatMap { place in
            guard let stakes = place.window.closeStakes(workspace: place.id),
                let name = place.window.listing(of: place.id)?.title
            else { return .failure(ControlError(.notFound, "That workspace is gone.")) }
            if stakes.needsForce, request.args.force != true {
                return .failure(Self.refusal(closing: "workspace \(name)", stakes))
            }
            place.window.removeWorkspace(place.id)
            return .success(NoPayload())
        }
    }

    private func newTab(_ request: ControlRequest) -> ControlReply {
        if let cwd = request.args.cwd, !cwd.hasPrefix("/") {
            return .failure(ControlError(.badRequest, "\(cwd) is not an absolute path."))
        }
        return workspace(request.args.workspace, for: request).flatMap { place in
            if let host = place.window.host(of: place.id), request.args.cmd != nil || request.args.cwd != nil {
                return .failure(
                    ControlError(
                        .refused,
                        "A tab on \(ControlAddress.hostPrefix + host.alias) takes no cmd or cwd. "
                            + "It starts the host's login shell."))
            }
            let cwd =
                request.args.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? callerCWD(in: place, for: request)
                ?? ShellLaunch.newSessionCWD(focused: place.window.sessionCWD(of: place.id))
            let command = request.args.cmd.flatMap { $0.isEmpty ? nil : $0 }
            guard let tab = place.window.openTab(in: place.id, cwd: cwd, command: command),
                let pane = place.window.firstPaneToken(of: tab)
            else { return .failure(ControlError(.failed, "The tab could not be opened.")) }
            if request.args.focus == true {
                place.window.selectTab(tab)
                raise(place.window)
            }
            let address = ControlAddress.tab(window: place.window.windowID, tab: tab.raw)
            return .success(TabResult(tab: address, pane: pane))
        }
    }

    private func selectTab(_ request: ControlRequest) -> ControlReply {
        tab(request.args.tab, for: request).map { place in
            place.window.selectTab(place.id)
            raise(place.window)
            return NoPayload()
        }
    }

    private func renameTab(_ request: ControlRequest) -> ControlReply {
        guard let title = request.args.title else {
            return .failure(ControlError(.badRequest, "tab.rename needs a title. An empty one clears it."))
        }
        return tab(request.args.tab, for: request).map { place in
            place.window.renameTab(place.id, to: title)
            return NoPayload()
        }
    }

    private func closeTab(_ request: ControlRequest) -> ControlReply {
        tab(request.args.tab, for: request).flatMap { place in
            guard let stakes = place.window.closeStakes(tab: place.id) else {
                return .failure(ControlError(.notFound, "That tab is gone."))
            }
            if stakes.needsForce, request.args.force != true {
                let address = ControlAddress.tab(window: place.window.windowID, tab: place.id.raw)
                return .failure(Self.refusal(closing: "tab \(address)", stakes))
            }
            if stakes.loginHost != nil { return Self.abandonLogin(holding: place.id, in: place.window) }
            place.window.removeTab(place.id)
            return .success(NoPayload())
        }
    }

    private func performAction(_ request: ControlRequest) -> ControlReply {
        guard let name = request.args.name else {
            return .failure(ControlError(.badRequest, "action needs the name of a keymap action."))
        }
        let actions = KeyInterceptor.ReservedChord.everyAction
        guard let action = KeyInterceptor.ReservedChord(token: name), actions.contains(action) else {
            let names = actions.map(\.actionToken).joined(separator: ", ")
            return .failure(ControlError(.notFound, "There is no action named \(name). The actions are \(names)."))
        }
        guard keyWindow() != nil else { return .failure(ControlError(.notFound, "No ZenTerm window is open.")) }
        runAction(action)
        return .success(NoPayload())
    }

    private func present(_ place: WorkspacePlace, focus: Bool?) -> any ControlPayload {
        if focus == true {
            place.window.activateWorkspace(place.id)
            raise(place.window)
        }
        guard let listing = place.window.listing(of: place.id) else { return NoPayload() }
        return WorkspaceResult(window: ControlAddress.window(place.window.windowID), workspace: listing)
    }

    func raise(_ window: WindowController) {
        guard !isInFront(window) else { return }
        bringForward(window)
    }

    static func refusal(closing name: String, _ stakes: CloseStakes) -> ControlError {
        var consequences: [String] = []
        if stakes.closesWindow { consequences.append("close the window") }
        if stakes.isRunning { consequences.append(stopping(stakes.panes, stakes.floats)) }
        if let host = stakes.loginHost {
            let tabs = stakes.loginTabs == 1 ? "tab" : "\(stakes.loginTabs) tabs"
            consequences.append("stop connecting to \(host) and close its \(tabs)")
        }
        return ControlError(
            .refused, "Closing \(name) would \(CloseWarning.list(consequences)).",
            details: ControlError.Details(panes: stakes.panes, floats: stakes.floats, closesWindow: stakes.closesWindow)
        )
    }

    static func abandonLogin(holding tab: TabID, in window: WindowController) -> ControlReply {
        if let workspace = window.workspaceID(of: tab) { window.removeWorkspace(workspace) }
        return .success(NoPayload())
    }

    static func stopping(_ panes: [ListResult.Pane], _ floats: [String]) -> String {
        let running = panes.map { $0.title.isEmpty ? "pane \($0.token)" : $0.title } + floats
        return running.isEmpty ? "stop what it is running" : "stop \(CloseWarning.list(running))"
    }
}
