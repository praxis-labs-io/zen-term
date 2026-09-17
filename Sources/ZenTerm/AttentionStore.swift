import Foundation
import TabKit

/// One window's attention: every surface latches its own, tabs and the window roll up by `max`. Main-thread only.
final class AttentionStore {
    private struct Entry {
        var tab: TabID?
        var latched: SurfaceAttention = .idle
        var seen = true
        var working = false
        var since: Date?
    }

    private var entries: [SurfaceID: Entry] = [:]

    // An unseen latch outlives the surface that raised it, the way tab-keyed state did before.
    private var residual: [TabID: (state: SurfaceAttention, since: Date?)] = [:]

    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func register(_ id: SurfaceID, tab: TabID?) {
        entries[id] = Entry(tab: tab)
    }

    /// Folds an unseen latch into its tab, so closing the pane that spoke does not un-color the tab.
    func release(_ id: SurfaceID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        guard !entry.seen, entry.latched != .idle, let tab = entry.tab else { return }
        let existing = residual[tab]
        residual[tab] = (
            max(existing?.state ?? .idle, entry.latched),
            earliest(existing?.since, entry.since)
        )
    }

    func record(_ id: SurfaceID, _ event: SurfaceAttention, seen: Bool) {
        guard var entry = entries[id] else { return }
        entry.latched = max(entry.latched, event)
        entry.seen = seen
        entry.since = seen || entry.latched == .idle ? nil : (entry.since ?? now())
        entries[id] = entry
    }

    /// A level, not an event: progress clearing has to be able to lower it again.
    func setWorking(_ id: SurfaceID, _ on: Bool) {
        entries[id]?.working = on
    }

    /// A visit: everything in the tab is seen and its latches drop, which is what clearing a tab meant before.
    func markSeen(tab: TabID) {
        for id in ids(in: tab) { markSeen(id) }
        residual[tab] = nil
    }

    func markSeen(_ id: SurfaceID) {
        entries[id]?.seen = true
        entries[id]?.latched = .idle
        entries[id]?.since = nil
    }

    func dropTab(_ tab: TabID) {
        for id in ids(in: tab) { entries[id] = nil }
        residual[tab] = nil
    }

    func state(of id: SurfaceID) -> SurfaceAttention {
        entries[id].map(effective) ?? .idle
    }

    func state(tab: TabID) -> SurfaceAttention {
        let surfaces = entries.values.filter { $0.tab == tab }.map(effective)
        return SurfaceAttention.rollup(surfaces + [residual[tab]?.state ?? .idle])
    }

    var windowState: SurfaceAttention {
        SurfaceAttention.rollup(entries.values.map(effective) + residual.values.map(\.state))
    }

    /// When the oldest thing still asking for you started asking, for the app-level summary.
    var waitingSince: Date? {
        let latched = entries.values.filter { !$0.seen && $0.latched != .idle }.compactMap(\.since)
        return (latched + residual.values.compactMap(\.since)).min()
    }

    private func ids(in tab: TabID) -> [SurfaceID] {
        entries.filter { $0.value.tab == tab }.map(\.key)
    }

    private func effective(_ entry: Entry) -> SurfaceAttention {
        max(entry.seen ? .idle : entry.latched, entry.working ? .working : .idle)
    }

    private func earliest(_ a: Date?, _ b: Date?) -> Date? {
        [a, b].compactMap { $0 }.min()
    }
}
