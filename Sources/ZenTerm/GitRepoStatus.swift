import Foundation

/// The last-known git answers per directory — is it a repo, and what branch is it on — probed off
/// the main thread.
///
/// Both answers are filesystem reads, and the chrome must never block the main queue on
/// filesystem I/O — a workspace on a network share or FUSE mount makes that read
/// unbounded, and the ⌘P picker used to run one per row per keystroke. So a row renders
/// from `known` / `branch` (instant, nil until something has probed the path) and its host calls
/// `refresh` to fill them in when the answers land.
///
/// Refreshing per open, rather than answering once for the life of the process, is what makes a
/// freshly `git init`ed folder answer without a relaunch, and a branch switched in a shell show up
/// the next time the picker opens.
///
/// Main-thread only: `known` reads the cache, and `refresh` hops back to main before writing it.
enum GitRepoStatus {
    /// One directory's answers. `branch` is nil for a directory that isn't a repo, and for a repo
    /// whose `HEAD` can't be read. `churn` arrives separately and later — see `refreshChurn`.
    private struct Status {
        var isRepo = false
        var branch: String?
        var churn: GitChurn?
    }

    private static var cache: [URL: Status] = [:]

    /// Whether `dir` is a repo, or nil when nothing has probed it yet.
    static func known(_ dir: URL) -> Bool? { cache[dir.standardizedFileURL]?.isRepo }

    /// The branch `dir` is on, or nil when nothing has probed it, it isn't a repo, or its `HEAD`
    /// didn't read.
    static func branch(_ dir: URL) -> String? { cache[dir.standardizedFileURL]?.branch }

    /// What `dir` has in flight, or nil until `refreshChurn` has answered for it.
    static func churn(_ dir: URL) -> GitChurn? { cache[dir.standardizedFileURL]?.churn }

    /// Probe every directory in `dirs` off-main, recording each answer and running `completion` on
    /// the main thread as it lands.
    ///
    /// One probe per directory rather than one pass over all of them: a single unreachable path
    /// would otherwise hold every other answer behind it, so the local repos in a list would sit
    /// badgeless until a dead mount finally timed out. That is the unbounded wait this type exists
    /// to remove, and batching would only have moved it off the main thread rather than removed it.
    ///
    /// `completion` therefore runs once per directory, not once per call, and never at all for an
    /// empty list. Callers re-read `known` for everything they render, which makes each run
    /// idempotent.
    static func refresh(_ dirs: [URL], completion: @escaping () -> Void) {
        for dir in dirs.map(\.standardizedFileURL) {
            DispatchQueue.global(qos: .userInitiated).async {
                let isRepo = GitRepo.isGitRepo(dir)
                let branch = isRepo ? GitRepo.currentBranch(dir) : nil
                DispatchQueue.main.async {
                    cache[dir, default: Status()].isRepo = isRepo
                    cache[dir, default: Status()].branch = branch
                    // A folder that stopped being a repo must not keep the counts it had when it
                    // was one.
                    if !isRepo { cache[dir, default: Status()].churn = nil }
                    completion()
                }
            }
        }
    }

    /// Churn probes run here rather than on the global queue: each is a blocking `git`, one per
    /// workspace, and an unbounded fan-out of them is what starves the very queue
    /// `GitRepoStatus.repoRoot` and the tool floats' `git:` gating share. Four at a time keeps a
    /// stalled mount from taking the app's worker threads with it.
    private static let churnQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Probe every directory in `dirs` for churn off-main, running `completion` on the main thread
    /// as each answer lands — including the answers that are "none", so a caller counting
    /// completions is never left waiting on one that will not come.
    ///
    /// Separate from `refresh` because it costs a different order of magnitude: `refresh` reads two
    /// files, this runs `git` once per directory. Keeping them apart is what lets a row show its
    /// branch immediately and fill the counts in behind it, rather than holding both behind a
    /// `git status` on a large repo.
    ///
    /// No fetch: `git status` reports ahead/behind against the remote-tracking ref already on disk.
    /// A ⌘P that hit the network would stall on a VPN or an auth prompt for a repo the user only
    /// wanted to open.
    ///
    /// Each call cancels the one before it. A picker closed and reopened must not leave the first
    /// open's probes running behind the second's.
    static func refreshChurn(_ dirs: [URL], completion: @escaping () -> Void) {
        churnQueue.cancelAllOperations()
        for dir in dirs.map(\.standardizedFileURL) {
            churnQueue.addOperation {
                let churn = churnNow(for: dir)
                DispatchQueue.main.async {
                    // A probe that failed clears the counts rather than leaving the last run's.
                    // `git status` exits nonzero on an `index.lock` held by a concurrent git, and a
                    // row must not go on asserting work that may no longer be there.
                    cache[dir, default: Status()].churn = churn
                    completion()
                }
            }
        }
    }

    /// One directory's counts, or nil when it isn't a repo or `git` can't answer for it.
    private static func churnNow(for dir: URL) -> GitChurn? {
        guard GitRepo.isGitRepo(dir),
            case .success(let output) = GitCommand.run(
                ["status", "--porcelain=v2", "--branch"], in: dir)
        else { return nil }
        return GitChurn.parse(output)
    }

    /// The enclosing repo root for `cwd`, resolved off-main and delivered on the main thread.
    /// Uncached on purpose: this answers for a pane's live cwd, which moves with every `cd`, and the
    /// walk is what has to leave the main queue — `GitRepo.repoRoot` probes every ancestor, so it's
    /// a run of stats rather than the single one `refresh` does per directory.
    static func repoRoot(for cwd: URL?, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let root = GitRepo.repoRoot(for: cwd)
            DispatchQueue.main.async { completion(root) }
        }
    }

    #if DEBUG
        /// Test-only reset, so one test's probes can't decide another test's assertions. Compiled
        /// out of release builds entirely, mirroring `ConfigLoader.defaultRootOverrideForTesting`.
        static func resetForTesting() { cache = [:] }
    #endif
}
