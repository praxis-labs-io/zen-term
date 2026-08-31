/// The ordered list of tabs in one window plus which is active. A value type —
/// pure ordering/active-index bookkeeping, no view or process state. Callers mint
/// unique `TabID`s and keep a parallel `[TabID: controller]` dict keyed by id, so
/// ordering and active live only here.
///
/// A `TabList` always holds at least one tab while in use: `close` returns `false`
/// the moment it would empty the list, at which point the caller closes the window
/// and stops using the list. Reading `activeID` on an emptied list is a programmer
/// error (see its precondition).
public struct TabList {
    public private(set) var order: [TabID]
    public private(set) var activeIndex: Int

    public init(first: TabID) {
        order = [first]
        activeIndex = 0
    }

    /// The active tab's id. Requires a non-empty list — once `close` empties the
    /// list (returns `false`) the caller must discard it rather than query here.
    public var activeID: TabID {
        precondition(
            !order.isEmpty,
            "activeID read on an empty TabList — the window should have been closed when close(_:) returned false")
        return order[activeIndex]
    }

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

    /// Move `id` `delta` slots along the order, clamped at both ends. Returns `false` when
    /// nothing moved (`id` absent, or already at the wall), so the caller can skip a re-render.
    /// Whichever tab was active stays active.
    @discardableResult
    public mutating func move(_ id: TabID, by delta: Int) -> Bool {
        guard let idx = order.firstIndex(of: id) else { return false }
        // Overflow lands at the wall the delta was heading for, rather than trapping: clamping
        // is what this promises, and `idx + delta` overflows before any clamp could run.
        let (sum, overflowed) = idx.addingReportingOverflow(delta)
        let requested = overflowed ? (delta > 0 ? Int.max : Int.min) : sum
        let target = min(max(requested, 0), order.count - 1)
        guard target != idx else { return false }
        let stillActive = order[activeIndex]
        order.remove(at: idx)
        order.insert(id, at: target)
        activeIndex = order.firstIndex(of: stillActive) ?? target
        return true
    }
}
