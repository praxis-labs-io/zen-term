import Foundation

/// The last-known "is this directory a git repo" answer per directory, probed off the main thread.
///
/// `GitRepo.isGitRepo` is a `fileExists` stat, and the chrome must never block the main queue on
/// filesystem I/O (ZEN-90) — a workspace on a network share or FUSE mount makes that stat
/// unbounded, and the ⌘⇧P picker used to run one per row per keystroke (ZEN-15). So a row renders
/// from `known` (instant, nil until something has probed the path) and its host calls `refresh` to
/// fill the badges in when the answers land.
///
/// Refreshing per open, rather than answering once for the life of the process, is what makes a
/// freshly `git init`ed folder show its badge without a relaunch.
///
/// Main-thread only: `known` reads the cache, and `refresh` hops back to main before writing it.
enum GitRepoStatus {
    private static var cache: [URL: Bool] = [:]

    /// The last-known answer for `dir`, or nil when nothing has probed it yet.
    static func known(_ dir: URL) -> Bool? { cache[dir.standardizedFileURL] }

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
                DispatchQueue.main.async {
                    cache[dir] = isRepo
                    completion()
                }
            }
        }
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
