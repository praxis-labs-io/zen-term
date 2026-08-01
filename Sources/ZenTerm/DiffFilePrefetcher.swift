import Foundation

/// Warms the syntax-highlight cache for a diff's files in the background (ZEN-239), so navigating to a
/// file is a cache hit — instant and already highlighted — instead of waiting on a fetch+parse. The
/// selected file is highlighted on its own foreground path (`DiffViewerOverlay.renderCurrentFile`); this
/// covers all the others. Owned by the overlay: it doesn't need to outlive one open, so "stop on close"
/// is just `cancelAll()` from `deinit`.
///
/// `schedule` and `cancelAll` must be called from the main thread only (the overlay calls them from
/// `apply`/`deinit`, both main) — `generation` is main-confined and not otherwise synchronized.
final class DiffFilePrefetcher {
    private let queue = OperationQueue()
    private let repoRoot: URL
    private let highlightStore: DiffHighlightStore
    /// Bumped on every (re)schedule and on cancel; a background result whose generation no longer matches
    /// is dropped, so a pass superseded by a changed reload (which cleared the store) can't repopulate it
    /// with stale spans.
    private var generation = 0

    /// Cap on live git subprocesses. Each operation fetches a file's two sides sequentially, so this bounds
    /// concurrent `git show`s at N, not 2N — enough to parallelize, low enough to leave the main thread and
    /// the selected file's own fetch headroom. Flat, like `DiffHighlighter`'s size ceilings.
    private static let maxConcurrency = 4

    init(repoRoot: URL, highlightStore: DiffHighlightStore) {
        self.repoRoot = repoRoot
        self.highlightStore = highlightStore
        queue.maxConcurrentOperationCount = Self.maxConcurrency
        // Below the selected file's `.userInitiated` fetch, so GCD favors the foreground path under
        // contention. Never set `underlyingQueue = .main` — that would serialize git spawns onto main.
        queue.qualityOfService = .utility
    }

    /// Warm every changed file except the selected one (already covered by the overlay's own fetch). Call
    /// once per `apply` — a fresh load or a changed reload. Retires the previous pass first.
    func schedule(_ status: GitDiffRunner.StatusLoad, excluding selectedKey: String?) {
        queue.cancelAllOperations()
        generation += 1
        // No repo on disk → nothing to fetch (and keeps tests from spawning git).
        guard FileManager.default.fileExists(atPath: repoRoot.path) else { return }
        let thisGeneration = generation
        for file in Self.candidates(in: status, excluding: selectedKey, store: highlightStore) {
            let key = file.highlightKey
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let self, operation?.isCancelled == false else { return }
                let spans = DiffHighlighter.enrichSync(file: file, repoRoot: self.repoRoot)
                guard operation?.isCancelled == false else { return }
                DispatchQueue.main.async {
                    guard self.generation == thisGeneration else { return }  // superseded — drop it
                    self.highlightStore.store(key, spans)
                }
            }
            queue.addOperation(operation)
        }
    }

    /// Stop everything — the overlay is closing, or a reload is about to discard the store.
    func cancelAll() {
        generation += 1  // orphan any result already past its own cancellation check
        queue.cancelAllOperations()
    }

    /// The files worth prefetching: every changed file across the three slices except the selected one
    /// (foreground-fetched), files already resolved in the store, and unsupported languages. A file with
    /// no extension stays in: its blob may still name a language via a shebang or modeline (ZEN-329).
    /// Keyed by `highlightKey`, so the same path in two slices is two distinct candidates. Pure, so the
    /// filtering is unit-testable without spawning git.
    static func candidates(
        in status: GitDiffRunner.StatusLoad, excluding selectedKey: String?, store: DiffHighlightStore
    ) -> [FileDiff] {
        (status.unstaged + status.staged + status.committed).filter { file in
            file.highlightKey != selectedKey && store.cached(file.highlightKey) == nil
                && (SyntaxLanguage.isSupported(path: file.path)
                    || SyntaxLanguage.isContentDetectable(path: file.path))
        }
    }
}
