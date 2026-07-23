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

/// Per-repo syntax-highlight cache that outlives a single diff-viewer open (ZEN-239). Held by the
/// `WindowController` and handed to each `DiffViewerOverlay`, so reopening the same repo paints its
/// files highlighted immediately instead of re-parsing from scratch. Keyed by file path; the overlay
/// clears it when a reload brings changed content, so a cached span set can never go stale. A reference
/// type on purpose — the store is shared, not copied.
final class DiffHighlightStore {
    private let lock = NSLock()
    /// nil value = "highlighted, but the file produced no spans" (unsupported language or all-plain), so a
    /// cache hit still means "don't re-parse".
    private var spans: [String: DiffFileSpans?] = [:]

    /// Keyed by `FileDiff.highlightKey` (scope+base+path), not bare path. Lock-guarded because the
    /// background prefetcher (`DiffFilePrefetcher`) may read `cached` off-main while the main thread
    /// stores/clears — all three are O(1), so a single `NSLock` is the right shape.
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

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        spans.removeAll()
    }
}
