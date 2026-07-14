import Foundation

/// App-wide LRU budget for *never-opened* pre-warmed lazygit surfaces (ZEN-55).
/// Each background lazygit costs a resident `-l -i` shell + lazygit process, and an
/// unbounded set of them eventually exhausts WindowServer surfaces (see
/// `GhosttySurfaceChurnTests`). A tab's pre-warm is admitted here; opening `⌘G`
/// removes it (promotion — a surface the user actually revealed is never evicted).
/// Past capacity, the oldest entry's evict closure runs, terminating its background
/// lazygit; that tab falls back to spawn-on-demand at the next `⌘G`.
///
/// Main-thread only, like all `TabController` surface lifecycle.
final class LazygitPrewarmPool {
    static let shared = LazygitPrewarmPool()

    private struct Entry {
        let owner: ObjectIdentifier
        let evict: () -> Void
    }

    /// Max never-opened background lazygits across all windows — the ZEN-55 tunable.
    private let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    func contains(_ owner: AnyObject) -> Bool {
        let id = ObjectIdentifier(owner)
        return entries.contains { $0.owner == id }
    }

    /// Register a fresh never-opened pre-warm (refreshing recency if already present),
    /// then evict the oldest entries past capacity. Each evicted entry is dropped from
    /// the pool BEFORE its closure runs, so a closure that re-enters `remove` (the
    /// discard path) is a harmless no-op.
    func admit(_ owner: AnyObject, onEvict: @escaping () -> Void) {
        remove(owner)
        entries.append(Entry(owner: ObjectIdentifier(owner), evict: onEvict))
        while entries.count > capacity {
            entries.removeFirst().evict()
        }
    }

    /// Drop `owner` without evicting — promotion (`⌘G` opened it) or teardown
    /// (discard/shutdown). A non-member is a no-op.
    func remove(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        entries.removeAll { $0.owner == id }
    }
}
