import Foundation

extension FileDiff {
    /// Identity for the syntax-highlight cache. Keyed on more than the path because the *same path* can
    /// appear in several slices at once — a file changed both in the working tree and since the base shows
    /// up in Unstaged and Committed — and each fetches a different pair of blobs (different scope, base,
    /// and old-path for a rename). Keying on path alone let one slice's spans clobber another's under the
    /// shared cache slot (ZEN-239): a committed new-file has no old side, which would blank the old column
    /// of the unstaged version of the same path.
    var highlightKey: String {
        "\(scope.rawValue)\u{1}\(baseSHA ?? "")\u{1}\(oldPath ?? "")\u{1}\(path)"
    }
}

/// Per-repo syntax-highlight cache that outlives a single diff-viewer open (ZEN-239). Owned by the
/// repo's `DiffViewerSession` (which the `WindowController` holds) and handed to each
/// `DiffViewerOverlay` as `session.highlights`, so reopening the same repo paints its files
/// highlighted immediately instead of re-parsing from scratch. Keyed by `FileDiff.highlightKey`; the
/// overlay evicts only the keys a reload actually changed, so an unchanged file keeps painting
/// highlighted while the changed one re-parses (ZEN-261). A reference type on purpose — the store is
/// shared, not copied.
final class DiffHighlightStore {
    private let lock = NSLock()
    /// nil value = "highlighted, but the file produced no spans" (unsupported language or all-plain), so a
    /// cache hit still means "don't re-parse".
    private var spans: [String: DiffFileSpans?] = [:]

    /// Keyed by `FileDiff.highlightKey` (scope+base+path), not bare path. Every caller today touches
    /// this on the main thread (the prefetcher reads `cached` from `schedule`, which is main-only, and
    /// hops its writes back to main), so the lock is insurance for a future off-main caller rather than
    /// load-bearing right now — don't go hunting for a race it's holding back. All three operations are
    /// O(1), so a single `NSLock` is the right shape and costs nothing on main.
    func cached(_ key: String) -> DiffFileSpans?? {
        lock.lock()
        defer { lock.unlock() }
        return spans[key]
    }

    func store(_ key: String, _ value: DiffFileSpans?) {
        lock.lock()
        defer { lock.unlock() }
        spans[key] = value
    }

    /// Drop the cached spans for `keys` and nothing else — a changed reload evicts only the files whose
    /// content moved, so every unchanged file keeps its spans and repaints with no re-parse (ZEN-261).
    /// Absent keys are ignored.
    func evict(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for key in keys { spans.removeValue(forKey: key) }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        spans.removeAll()
    }
}
