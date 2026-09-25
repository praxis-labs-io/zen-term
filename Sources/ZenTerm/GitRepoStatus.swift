import Foundation

enum GitRepoStatus {
    private struct Status {
        var isRepo = false
        var repoRoot: URL?
        var branch: String?
        var churn: GitChurn?
    }

    private static var cache: [URL: Status] = [:]

    /// Per caller, because two windows' pickers share the queue and a global cancel drops the other's answers.
    final class RefreshToken {
        fileprivate(set) var isCancelled = false
        fileprivate var operations: [Operation] = []

        func cancel() {
            isCancelled = true
            for operation in operations { operation.cancel() }
        }
    }

    static func known(_ dir: URL) -> Bool? { cache[dir.standardizedFileURL]?.isRepo }

    static func branch(_ dir: URL) -> String? { cache[dir.standardizedFileURL]?.branch }

    static func churn(_ dir: URL) -> GitChurn? { cache[dir.standardizedFileURL]?.churn }

    static func repoRoot(_ dir: URL) -> URL? { cache[dir.standardizedFileURL]?.repoRoot }

    static func refresh(_ dirs: [URL], completion: @escaping () -> Void) {
        for dir in dirs.map(\.standardizedFileURL) {
            DispatchQueue.global(qos: .userInitiated).async {
                let root = GitRepo.repoRoot(for: dir)
                let branch = root.flatMap(GitRepo.currentBranch)
                DispatchQueue.main.async {
                    cache[dir, default: Status()].isRepo = root != nil
                    cache[dir, default: Status()].repoRoot = root
                    cache[dir, default: Status()].branch = branch
                    if root == nil { cache[dir, default: Status()].churn = nil }
                    completion()
                }
            }
        }
    }

    /// Bounded so a stalled mount cannot take the app's worker threads with it.
    private static let churnQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    @discardableResult
    static func refreshChurn(_ dirs: [URL], completion: @escaping () -> Void) -> RefreshToken {
        let token = RefreshToken()
        for dir in dirs.map(\.standardizedFileURL) {
            let probe = BlockOperation {
                let churn = churnNow(for: dir)
                DispatchQueue.main.async {
                    guard !token.isCancelled else { return }
                    cache[dir, default: Status()].churn = churn
                    completion()
                }
            }
            token.operations.append(probe)
            churnQueue.addOperation(probe)
        }
        return token
    }

    private static let worktreeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    @discardableResult
    static func refreshWorktrees(
        _ dirs: [URL], completion: @escaping (URL, WorktreeListing) -> Void
    ) -> RefreshToken {
        let token = RefreshToken()
        for dir in dirs.map(\.standardizedFileURL) {
            let probe = BlockOperation {
                let commonDir = WorktreeStore.commonDir(of: dir)
                let worktrees = (try? WorktreeStore.list(in: dir, pruning: false)) ?? []
                DispatchQueue.main.async {
                    guard !token.isCancelled else { return }
                    completion(dir, WorktreeListing(commonDir: commonDir, worktrees: worktrees))
                }
            }
            token.operations.append(probe)
            worktreeQueue.addOperation(probe)
        }
        return token
    }

    /// `--no-optional-locks` so a probe never takes the index lock from the user's own git.
    private static func churnNow(for dir: URL) -> GitChurn? {
        guard GitRepo.repoRoot(for: dir) != nil,
            case .success(let output) = GitCommand.run(
                ["--no-optional-locks", "status", "--porcelain=v2", "--branch"], in: dir)
        else { return nil }
        return GitChurn.parse(output)
    }

    /// Serial so a hung mount holds one thread across every window, and never a churn probe's slot.
    private static let removedWorktreeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    static func removedWorktrees(among roots: [URL], completion: @escaping (Set<URL>) -> Void) {
        removedWorktreeQueue.addOperation {
            let removed = Set(roots.filter(WorktreeStore.isRemoved(at:)))
            DispatchQueue.main.async { completion(removed) }
        }
    }

    static func createOptions(in dir: URL, completion: @escaping (WorktreeStore.CreateOptions) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let options = WorktreeStore.createOptions(in: dir)
            DispatchQueue.main.async { completion(options) }
        }
    }

    static func repoRoot(for cwd: URL?, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let root = GitRepo.repoRoot(for: cwd)
            DispatchQueue.main.async { completion(root) }
        }
    }

    #if DEBUG
        static func resetForTesting() { cache = [:] }
    #endif
}
