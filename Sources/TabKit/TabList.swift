/// The ordered set of tabs in one window plus which is active. A value type —
/// pure ordering/active-index bookkeeping, no view or process state. The window
/// chrome keeps a parallel `[TabID: controller]` dict keyed by id, so ordering and
/// active live only here.
public struct TabList {
    public private(set) var order: [TabID]
    public private(set) var activeIndex: Int

    public init(first: TabID) {
        order = [first]
        activeIndex = 0
    }

    public var activeID: TabID { order[activeIndex] }

    /// Append a tab and make it active.
    public mutating func add(_ id: TabID) {
        order.append(id)
        activeIndex = order.count - 1
    }

    /// Make `id` active if present; no-op otherwise.
    public mutating func select(_ id: TabID) {
        guard let idx = order.firstIndex(of: id) else { return }
        activeIndex = idx
    }

    /// Make the tab at `index` active, clamped into range.
    public mutating func select(index: Int) {
        guard !order.isEmpty else { return }
        activeIndex = min(max(index, 0), order.count - 1)
    }

    /// Remove `id`. Returns `false` iff the list is now empty (caller closes the
    /// window). When the active tab is closed, its right neighbor becomes active
    /// (clamped to the new last tab if it was rightmost).
    @discardableResult
    public mutating func close(_ id: TabID) -> Bool {
        guard let idx = order.firstIndex(of: id) else { return true }
        order.remove(at: idx)
        if order.isEmpty { activeIndex = 0; return false }
        if idx < activeIndex {
            activeIndex -= 1
        } else if idx == activeIndex {
            activeIndex = min(idx, order.count - 1)
        }
        return true
    }
}
