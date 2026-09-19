import Foundation

// The sidebar's order: groups by seat, a workspace leading its worktrees, each group in open order.
@MainActor
struct WorkspaceOrder {
    enum Entry: Equatable {
        case workspace(WorkspaceID)
        case worktree(WorkspaceID)
        case ghost(Workspace)
    }

    private enum GroupKey: Hashable {
        case folder(String)
        case alone(WorkspaceID)
    }

    let entries: [Entry]

    static func groupFolder(of workspace: WorkspaceController) -> String? {
        if let origin = workspace.origin { return origin.parent.path.standardizedFileURL.path }
        return workspace.isDefault ? nil : workspace.folder.standardizedFileURL.path
    }

    init(_ workspaces: [WorkspaceController]) {
        var seats: [(key: GroupKey, seat: Int)] = []
        var leads: [GroupKey: WorkspaceID] = [:]
        var ghosts: [GroupKey: Workspace] = [:]
        var worktrees: [GroupKey: [WorkspaceID]] = [:]
        for workspace in workspaces {
            let key: GroupKey
            if let origin = workspace.origin {
                key = .folder(origin.parent.path.standardizedFileURL.path)
                worktrees[key, default: []].append(workspace.id)
                if ghosts[key] == nil { ghosts[key] = origin.parent }
            } else {
                let folder = Self.groupFolder(of: workspace).map(GroupKey.folder)
                key = folder.flatMap { leads[$0] == nil ? $0 : nil } ?? .alone(workspace.id)
                leads[key] = workspace.id
            }
            if !seats.contains(where: { $0.key == key }) { seats.append((key, workspace.seat)) }
        }
        entries = seats.sorted { $0.seat < $1.seat }.flatMap { key, _ -> [Entry] in
            let lead = leads[key].map(Entry.workspace) ?? ghosts[key].map(Entry.ghost)
            return (lead.map { [$0] } ?? []) + (worktrees[key] ?? []).map(Entry.worktree)
        }
    }

    var navigable: [WorkspaceID] {
        entries.compactMap {
            switch $0 {
            case .workspace(let id), .worktree(let id): return id
            case .ghost: return nil
            }
        }
    }
}
