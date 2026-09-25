import Foundation

// A worktree deleted under an open workspace, and the folder new sessions start in instead.
struct RemovedCheckout {
    let root: URL
    let standIn: URL

    func relocating(_ cwd: URL?) -> URL? { GitRepo.isInside(cwd, root) ? standIn : cwd }
}
