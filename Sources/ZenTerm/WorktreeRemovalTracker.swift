import Foundation

// App-wide, so no window opens a tab into a worktree still being deleted. Main-thread only.
final class WorktreeRemovalTracker {
    // Past this, `git` has stopped answering and must not hold the process open.
    static let quitBudget: TimeInterval = 15

    private(set) var inFlight: Set<URL> = []

    enum Change {
        case began(URL)
        case removed(URL)
        case failed(URL)
    }

    var onChanged: ((Change) -> Void)?

    private final class Waiter {
        var completion: (() -> Void)?
        init(_ completion: @escaping () -> Void) { self.completion = completion }
    }
    private var waiters: [Waiter] = []

    func remove(_ worktree: Worktree, in parent: URL, completion: @escaping (Error?) -> Void) {
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

    // Quit waits on this: exiting mid-delete leaves a half-removed folder and git's entry for it.
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
