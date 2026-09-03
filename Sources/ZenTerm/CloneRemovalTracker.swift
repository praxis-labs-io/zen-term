import Foundation

/// The clones whose delete is still running, shared by every window.
///
/// Deleting a clone takes tens of seconds on a real repo, and it stays on disk and in
/// `CloneStore.list` for all of it. The picker shows those rows as removing and refuses to open
/// them, and that guard has to be app-wide: the directory is going away whichever window you are
/// looking from, so a second window listing it as an ordinary row would drop a tab into it.
///
/// Main-thread only, which is where every caller already is: `WindowController` marks a removal as
/// it starts one and clears it on the way back from the delete.
final class CloneRemovalTracker {
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
