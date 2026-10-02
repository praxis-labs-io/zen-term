import ControlProtocol
import Foundation
import TabKit

struct WorkspacePlace {
    let window: WindowController
    let id: WorkspaceID
}

struct TabPlace {
    let window: WindowController
    let id: TabID
}

struct CallerContext {
    let window: WindowController
    let workspace: WorkspaceID
    let tab: TabID?
    let pane: PaneHandle?
}

extension ControlResponder {
    func caller(_ request: ControlRequest) -> Result<CallerContext, ControlError> {
        if let token = request.caller?.pane {
            guard let found = locate(pane: token), let workspace = found.window.workspaceID(of: found.tab) else {
                return .failure(ControlError(.notFound, "There is no pane \(token)."))
            }
            return .success(
                CallerContext(window: found.window, workspace: workspace, tab: found.tab, pane: found.pane))
        }
        guard let window = keyWindow() else { return .failure(ControlError(.notFound, "No ZenTerm window is open.")) }
        let workspace = window.activeWorkspaceID
        return .success(
            CallerContext(window: window, workspace: workspace, tab: window.activeTab(of: workspace), pane: nil))
    }

    func workspace(_ address: String?, for request: ControlRequest) -> Result<WorkspacePlace, ControlError> {
        guard let address else {
            return caller(request).map { WorkspacePlace(window: $0.window, id: $0.workspace) }
        }
        return findOpenWorkspace(address)
    }

    func findOpenWorkspace(_ address: String) -> Result<WorkspacePlace, ControlError> {
        let matches = windows().flatMap { window in
            window.runningWorkspaces().compactMap { running -> WorkspacePlace? in
                guard let id = running.id, Self.names(running, address) else { return nil }
                return WorkspacePlace(window: window, id: id)
            }
        }
        switch matches.count {
        case 0: return .failure(ControlError(.notFound, "No workspace is open at \(address)."))
        case 1: return .success(matches[0])
        default: return .failure(ControlError(.ambiguous, "\(address) names \(matches.count) open workspaces."))
        }
    }

    private static func names(_ running: RunningWorkspace, _ address: String) -> Bool {
        switch ControlAddress.Workspace(address) {
        case .folder(let path): return running.folder.standardizedFileURL.path == standardized(path)
        case .host: return false
        case .title(let title): return running.name == title
        }
    }

    func tab(_ address: String?, for request: ControlRequest) -> Result<TabPlace, ControlError> {
        guard let address else {
            return caller(request).flatMap { context in
                guard let tab = context.tab else { return .failure(ControlError(.notFound, "No tab is open.")) }
                return .success(TabPlace(window: context.window, id: tab))
            }
        }
        guard let (window, tab) = ControlAddress.tab(address) else {
            return .failure(ControlError(.badRequest, "\(address) is not a tab address like w1.t3."))
        }
        guard let holder = windows().first(where: { $0.windowID == window }),
            holder.workspaceID(of: TabID(tab)) != nil
        else { return .failure(ControlError(.notFound, "There is no tab \(address).")) }
        return .success(TabPlace(window: holder, id: TabID(tab)))
    }

    func callerCWD(in place: WorkspacePlace, for request: ControlRequest) -> URL? {
        guard case .success(let context) = caller(request), context.window === place.window,
            context.workspace == place.id
        else { return nil }
        return context.pane?.cwd
    }
}
