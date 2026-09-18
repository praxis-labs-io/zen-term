/// Tab order and the active tab for one workspace. Discard it once `close` returns false.
public struct TabList {
    public private(set) var order: [TabID]
    public private(set) var activeIndex: Int

    public init(first: TabID) {
        order = [first]
        activeIndex = 0
    }

    /// Traps on an emptied list.
    public var activeID: TabID {
        precondition(
            !order.isEmpty,
            "activeID read on an empty TabList — the window should have been closed when close(_:) returned false")
        return order[activeIndex]
    }

    /// Appends `id` and makes it active.
    public mutating func add(_ id: TabID) {
        order.append(id)
        activeIndex = order.count - 1
    }

    public mutating func select(_ id: TabID) {
        guard let idx = order.firstIndex(of: id) else { return }
        activeIndex = idx
    }

    /// Makes the tab at `index` active, clamped into range.
    public mutating func select(index: Int) {
        guard !order.isEmpty else { return }
        activeIndex = min(max(index, 0), order.count - 1)
    }

    /// Returns false when the list is now empty. Closing the active tab activates its right neighbor.
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

    /// Moves `id` by `delta` slots, clamped. Returns false when nothing moved. The active tab stays active.
    @discardableResult
    public mutating func move(_ id: TabID, by delta: Int) -> Bool {
        guard let idx = order.firstIndex(of: id) else { return false }
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
