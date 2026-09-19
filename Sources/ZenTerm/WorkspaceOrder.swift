import Foundation

// The sidebar's order: each group sits where its first member opened, a workspace leads its worktrees.
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

    init(_ workspaces: [WorkspaceController]) {
        var keys: [GroupKey] = []
        var leads: [GroupKey: WorkspaceID] = [:]
        var ghosts: [GroupKey: Workspace] = [:]
        var worktrees: [GroupKey: [WorkspaceID]] = [:]
        for workspace in workspaces {
            let key: GroupKey
            if let origin = workspace.origin {
                key = .folder(origin.parent.path.standardizedFileURL.path)
                worktrees[key, default: []].append(workspace.id)
                if leads[key] == nil, ghosts[key] == nil { ghosts[key] = origin.parent }
            } else {
                let folder = GroupKey.folder(workspace.folder.standardizedFileURL.path)
                key = workspace.isDefault || leads[folder] != nil ? .alone(workspace.id) : folder
                leads[key] = workspace.id
            }
            if !keys.contains(key) { keys.append(key) }
        }
        entries = keys.flatMap { key -> [Entry] in
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
