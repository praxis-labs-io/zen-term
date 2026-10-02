import ControlProtocol
import Foundation

extension ControlResponder {
    func listWorktrees(_ request: ControlRequest, reply: @escaping (ControlReply) -> Void) {
        withWorktreeEntry(request, reply: reply) { entry in
            DispatchQueue.global(qos: .userInitiated).async {
                let listed = Result { try WorktreeStore.list(in: entry.path, pruning: false) }
                DispatchQueue.main.async {
                    switch listed {
                    case .success(let worktrees):
                        reply(.success(WorktreeListResult(worktrees: worktrees.map(Self.listing))))
                    case .failure(let error):
                        reply(.failure(ControlError(.failed, error.localizedDescription)))
                    }
                }
            }
        }
    }

    func createWorktree(_ request: ControlRequest, reply: @escaping (ControlReply) -> Void) {
        guard let branch = request.args.branch, !branch.isEmpty else {
            return reply(.failure(ControlError(.badRequest, "worktree.create needs a branch.")))
        }
        let base: WorktreeStore.Base
        switch request.args.base {
        case nil, "default": base = .defaultBranch
        case "current": base = .currentCheckout
        case let other?:
            return reply(.failure(ControlError(.badRequest, "base is default or current, not \(other).")))
        }
        let made: NewWorktreeOverlay.Request =
            request.args.existing == true ? .existingBranch(branch) : .newBranch(branch, base)
        withWorktreeEntry(request, reply: reply) { entry in
            let target = RepoPickerOverlay.CreateTarget(workspace: entry, repo: entry.path)
            WorktreeCreation.start(made, from: target) { result in
                switch result {
                case .success(let created): reply(open(created, for: request))
                case .failure(let error): reply(.failure(ControlError(.failed, error.localizedDescription)))
                }
            }
        }
    }

    func removeWorktree(_ request: ControlRequest, reply: @escaping (ControlReply) -> Void) {
        let target: WorktreeTarget
        switch (request.args.path, request.args.branch) {
        case (let path?, _) where path.hasPrefix("/"): target = .path(path)
        case (let path?, _): return reply(.failure(ControlError(.badRequest, "\(path) is not an absolute path.")))
        case (nil, let branch?) where !branch.isEmpty: target = .branch(branch)
        default: return reply(.failure(ControlError(.badRequest, "worktree.remove needs a worktree's path or branch.")))
        }
        withWorktreeEntry(request, reply: reply) { entry in
            DispatchQueue.global(qos: .userInitiated).async {
                let found = Self.find(target, in: entry)
                DispatchQueue.main.async {
                    switch found {
                    case .success(let (worktree, state)):
                        remove(
                            worktree, holding: state, from: entry.path, force: request.args.force == true, reply: reply)
                    case .failure(let error): reply(.failure(error))
                    }
                }
            }
        }
    }

    private func open(_ created: WorktreeCreation.Created, for request: ControlRequest) -> ControlReply {
        let path = created.origin.path.path
        let callerWindow = try? caller(request).get().window
        guard
            let window = windows().first(where: { $0.holdsWorkspace(at: created.origin.parent.path) })
                ?? callerWindow ?? keyWindow()
        else { return .failure(ControlError(.failed, "The worktree is at \(path), but no window is open to show it.")) }
        let id = window.openConfiguredWorkspace(created.workspace, origin: created.origin)
        if request.args.focus == true {
            window.activateWorkspace(id)
            raise(window)
        }
        guard let listing = window.listing(of: id) else {
            return .failure(ControlError(.failed, "The worktree is at \(path), but its workspace closed."))
        }
        let carry = WorktreeResult.Carry(
            carried: created.carry.carried,
            skipped: created.carry.lost.map { WorktreeResult.Skipped(name: $0.name, reason: $0.reason.explanation) })
        return .success(
            WorktreeResult(
                path: path, carry: carry, window: ControlAddress.window(window.windowID), workspace: listing))
    }

    private func remove(
        _ worktree: Worktree, holding state: WorktreeState?, from repo: URL, force: Bool,
        reply: @escaping (ControlReply) -> Void
    ) {
        guard !worktreeRemovals.isRemoving(worktree.path) else {
            return reply(.failure(ControlError(.failed, "\(worktree.name) is already being removed.")))
        }
        guard !worktree.isLocked else {
            let locked = WorktreeStore.WorktreeError.isLocked(worktree.path).localizedDescription
            return reply(.failure(ControlError(.refused, locked)))
        }
        if !force, let refusal = refusal(removing: worktree, holding: state) { return reply(.failure(refusal)) }
        worktreeRemovals.remove(worktree, in: repo) { error in
            reply(error.map { .failure(ControlError(.failed, $0.localizedDescription)) } ?? .success(NoPayload()))
        }
    }

    private func refusal(removing worktree: Worktree, holding state: WorktreeState?) -> ControlError? {
        let stakes = windows().map { $0.closeStakes(atPath: worktree.path) }
        let isRunning = stakes.contains(where: \.isRunning)
        guard !isRunning, state?.isClean == true else {
            let details = ControlError.Details(
                panes: stakes.flatMap(\.panes), floats: stakes.flatMap(\.floats),
                closesWindow: stakes.contains(where: \.closesWindow), files: state.map { $0.files.map(\.path) },
                lostCommits: state?.lostCommits)
            let message = Self.refusalMessage(removing: worktree, holding: state, stopping: isRunning ? details : nil)
            return ControlError(.refused, message, details: details)
        }
        return nil
    }

    private static func refusalMessage(
        removing worktree: Worktree, holding state: WorktreeState?, stopping running: ControlError.Details?
    ) -> String {
        let stop = running.map { running in
            let named = running.panes.map { $0.title.isEmpty ? "pane \($0.token)" : $0.title } + running.floats
            return named.isEmpty ? "stop what it is running" : "stop \(named.joined(separator: ", "))"
        }
        guard let state else {
            let unread = "Couldn't read \(worktree.name) to check for uncommitted files or commits."
            return stop.map { "\(unread) Removing it would \($0)." } ?? unread
        }
        let lost = [
            state.lostCommits > 0 ? WorktreeRemovalMessage.counted(state.lostCommits, "commit") : nil,
            state.files.isEmpty ? nil : WorktreeRemovalMessage.counted(state.files.count, "uncommitted file"),
        ].compactMap { $0 }
        let lose = lost.isEmpty ? nil : "lose \(lost.joined(separator: " and "))"
        return "Removing \(worktree.name) would \([stop, lose].compactMap { $0 }.joined(separator: " and "))."
    }

    private func withWorktreeEntry(
        _ request: ControlRequest, reply: @escaping (ControlReply) -> Void, then body: @escaping (Workspace) -> Void
    ) {
        let address: String
        switch worktreeParent(request) {
        case .success(let found): address = found
        case .failure(let error): return reply(.failure(error))
        }
        loadWorkspaces { entries in
            let matches = entries.filter { Self.names($0, address) }
            switch (matches.count, ControlAddress.Workspace(address)) {
            case (1, _): body(matches[0])
            case (0, .folder(let path)):
                reply(
                    .failure(
                        ControlError(
                            .refused,
                            "\(path) is not in the workspaces file. Worktrees are made from a configured workspace.")))
            case (0, _): reply(.failure(ControlError(.notFound, "No workspace is open or configured at \(address).")))
            default:
                reply(.failure(ControlError(.ambiguous, "\(address) names \(matches.count) configured workspaces.")))
            }
        }
    }

    private func worktreeParent(_ request: ControlRequest) -> Result<String, ControlError> {
        let open: WorkspacePlace
        if let address = request.args.workspace {
            if case .host = ControlAddress.Workspace(address) {
                return .failure(ControlError(.notFound, "There is no workspace \(address)."))
            }
            switch findOpenWorkspace(address) {
            case .success(let place): open = place
            case .failure(let error) where error.code == .notFound: return .success(address)
            case .failure(let error): return .failure(error)
            }
        } else {
            switch caller(request) {
            case .success(let context): open = WorkspacePlace(window: context.window, id: context.workspace)
            case .failure(let error): return .failure(error)
            }
        }
        guard let folder = open.window.worktreeParentFolder(of: open.id) else {
            return .failure(ControlError(.notFound, "That workspace is gone."))
        }
        return .success(folder.standardizedFileURL.path)
    }

    private nonisolated static func find(_ target: WorktreeTarget, in entry: Workspace)
        -> Result<(Worktree, WorktreeState?), ControlError>
    {
        let listed: [Worktree]
        do {
            listed = try WorktreeStore.list(in: entry.path, pruning: false)
        } catch {
            return .failure(ControlError(.failed, error.localizedDescription))
        }
        let match: Worktree?
        switch target {
        case .branch(let branch): match = listed.first { $0.branch == branch }
        case .path(let path):
            let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            match = listed.first { $0.path.resolvingSymlinksInPath().standardizedFileURL == wanted }
        }
        guard let worktree = match else {
            return .failure(ControlError(.notFound, "\(entry.title) has no worktree \(target.text)."))
        }
        return .success((worktree, WorktreeStore.state(at: worktree.path, countingLostCommits: true)))
    }

    private static func listing(_ worktree: Worktree) -> WorktreeListResult.Worktree {
        WorktreeListResult.Worktree(
            path: worktree.path.path, branch: worktree.branch, head: worktree.head, locked: worktree.isLocked)
    }

    enum WorktreeTarget {
        case path(String)
        case branch(String)

        var text: String {
            switch self {
            case .path(let path): return "at \(path)"
            case .branch(let branch): return "on \(branch)"
            }
        }
    }
}
