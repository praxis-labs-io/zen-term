import Foundation

/// The worktrees whose delete is still running, shared by every window, and the place those
/// deletes run from.
///
/// A worktree carrying an install is a quarter of a million files, and it stays on disk and in
/// `git worktree list` for the whole delete. The picker shows those rows as removing and refuses to
/// open them, and that guard has to be app-wide: the directory is going away whichever window you
/// are looking from, so a second window listing it as an ordinary row would drop a tab into it.
///
/// Main-thread only, which is where every caller already is.
final class WorktreeRemovalTracker {
    /// The longest a quit waits on a delete. Seconds is the measured cost of the worst case, so a
    /// wait past this is a `git` that has stopped answering and must not hold the process open.
    static let quitBudget: TimeInterval = 15

    private(set) var inFlight: Set<URL> = []

    /// What happened to one worktree. `removed` is the only case where the folder is gone, so it
    /// is the only one that closes the tabs that were open in it.
    enum Change {
        case began(URL)
        case removed(URL)
        case failed(URL)
    }

    /// Told each of the above. `AppDelegate` fans it out to every window.
    var onChanged: ((Change) -> Void)?

    private final class Waiter {
        var completion: (() -> Void)?
        init(_ completion: @escaping () -> Void) { self.completion = completion }
    }
    private var waiters: [Waiter] = []

    /// Delete the worktree, holding the claim until the files are gone.
    ///
    /// Owned here rather than by the window that asked, because that window may not outlive the
    /// call: the tabs open in the worktree close when it is gone, and closing a window's last tab
    /// closes the window. `completion` carries the failure and is the caller's to weaken; the
    /// claim and the fan-out are not, and always run.
    func remove(_ worktree: Worktree, in parent: URL, completion: @escaping (Error?) -> Void) {
        // Two windows can each raise a confirm for one worktree. A second delete would fail and
        // toast, and the first `finish` would clear the sole claim while it was still running.
        guard !isRemoving(worktree.path) else { return }
        begin(worktree.path)
        onChanged?(.began(worktree.path))
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WorktreeStore.remove(worktree, in: parent) }
            DispatchQueue.main.async {
                self.finish(worktree.path)
                switch result {
                case .success:
                    self.onChanged?(.removed(worktree.path))
                    completion(nil)
                case .failure(let error):
                    self.onChanged?(.failed(worktree.path))
                    completion(error)
                }
            }
        }
    }

    /// Run `completion` once nothing is in flight, or once `budget` has passed. Quit waits on this:
    /// exiting mid-delete leaves a half-removed folder and git's entry for it still in place.
    func whenIdle(within budget: TimeInterval = quitBudget, then completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !inFlight.isEmpty else { return completion() }
        let waiter = Waiter(completion)
        waiters.append(waiter)
        DispatchQueue.main.asyncAfter(deadline: .now() + budget) { [weak self] in
            self?.fire(waiter)
        }
    }

    func begin(_ path: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        inFlight.insert(path.standardizedFileURL)
    }

    func finish(_ path: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        inFlight.remove(path.standardizedFileURL)
        guard inFlight.isEmpty else { return }
        for waiter in waiters { fire(waiter) }
    }

    func isRemoving(_ path: URL) -> Bool { inFlight.contains(path.standardizedFileURL) }

    private func fire(_ waiter: Waiter) {
        guard let completion = waiter.completion else { return }
        waiter.completion = nil
        waiters.removeAll { $0 === waiter }
        completion()
    }
}
