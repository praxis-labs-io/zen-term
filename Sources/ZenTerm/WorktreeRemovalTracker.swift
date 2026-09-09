import Foundation

/// The worktrees whose delete is still running, shared by every window.
///
/// A worktree carrying an install is a quarter of a million files, and it stays on disk and in
/// `git worktree list` for the whole delete. The picker shows those rows as removing and refuses to
/// open them, and that guard has to be app-wide: the directory is going away whichever window you
/// are looking from, so a second window listing it as an ordinary row would drop a tab into it.
///
/// Main-thread only, which is where every caller already is.
final class WorktreeRemovalTracker {
    private(set) var inFlight: Set<URL> = []

    func begin(_ path: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        inFlight.insert(path.standardizedFileURL)
    }

    func finish(_ path: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        inFlight.remove(path.standardizedFileURL)
    }

    func isRemoving(_ path: URL) -> Bool { inFlight.contains(path.standardizedFileURL) }
}
