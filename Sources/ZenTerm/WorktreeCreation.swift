import Foundation

enum WorktreeCreation {
    struct Created {
        let workspace: Workspace
        let origin: WorktreeOrigin
        let carry: CarryReport
    }

    static func start(
        _ request: NewWorktreeOverlay.Request, from target: RepoPickerOverlay.CreateTarget,
        onPhase: ((String) -> Void)? = nil, completion: @escaping (Result<Created, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try run(request, from: target, onPhase: onPhase) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func run(
        _ request: NewWorktreeOverlay.Request, from target: RepoPickerOverlay.CreateTarget,
        onPhase: ((String) -> Void)?
    ) throws -> Created {
        let workspace = target.workspace
        let worktree: Worktree
        switch request {
        case .newBranch(let branch, let base):
            worktree = try WorktreeStore.create(branch: branch, base: base, in: target.repo)
        case .existingBranch(let branch):
            worktree = try WorktreeStore.create(existingBranch: branch, in: target.repo)
        }
        let repoRoot = GitRepo.repoRoot(for: workspace.path)
        let opened = RepoPickerOverlay.workspace(for: worktree, parent: workspace, repoRoot: repoRoot)
        let report = WorktreeCarry.copy(
            workspace.carry, from: workspace.path, intoCheckout: worktree.path, repoRoot: repoRoot,
            onEntry: onPhase.map { onPhase in
                { name in DispatchQueue.main.async { onPhase("Copying \(name)") } }
            })
        return Created(workspace: opened, origin: WorktreeOrigin(parent: workspace, worktree: worktree), carry: report)
    }
}
