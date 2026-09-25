import Foundation
import TabKit

/// Where a waiting agent is answered: its own pane, or the tab holding what it left behind when the pane exited.
enum WaitingTarget: Equatable {
    case surface(SurfaceID)
    case tab(TabID)
}

/// One window's attention: every surface latches its own, tabs and the window roll up by `max`. Main-thread only.
final class AttentionStore {
    private struct Entry {
        var tab: TabID?
        var latched: SurfaceAttention = .idle
        var seen = true
        var working = false
        var since: Date?
        // Its own clock, because `since` dates from the first latch of any kind, a completion included.
        var waitingSince: Date?
        var agentLatched: SurfaceAttention = .idle
        var agentSince: Date?
    }

    private var entries: [SurfaceID: Entry] = [:]

    // `waiting` is a count, not a flag: two agents that each asked and exited are still two.
    // `waitingSince` is its own clock, because a completion folded earlier would otherwise date the question.
    private var residual: [TabID: (state: SurfaceAttention, since: Date?, waiting: Int, waitingSince: Date?)] = [:]

    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func register(_ id: SurfaceID, tab: TabID?) {
        entries[id] = Entry(tab: tab)
    }

    func tab(of id: SurfaceID) -> TabID? { entries[id]?.tab }

    /// Folds an unseen latch into its tab, so closing the pane that spoke does not un-color the tab.
    func release(_ id: SurfaceID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        guard !entry.seen, entry.latched != .idle, let tab = entry.tab else { return }
        let existing = residual[tab]
        residual[tab] = (
            max(existing?.state ?? .idle, entry.latched),
            earliest(existing?.since, entry.since),
            (existing?.waiting ?? 0) + (entry.latched == .waiting ? 1 : 0),
            entry.latched == .waiting
                ? earliest(existing?.waitingSince, entry.waitingSince) : existing?.waitingSince
        )
    }

    // Focus gates the toast, never the agent latch: the notification is one-shot, so blocked outlives a glance.
    func record(_ id: SurfaceID, _ event: SurfaceAttention, seen: Bool) {
        latchAgent(id, event)
        guard !seen else { return markSeen(id) }
        guard var entry = entries[id] else { return }
        entry.latched = max(entry.latched, event)
        entry.seen = false
        entry.since = entry.latched == .idle ? nil : (entry.since ?? now())
        if entry.latched == .waiting { entry.waitingSince = entry.waitingSince ?? now() }
        entries[id] = entry
    }

    /// A level, not an event: progress clearing has to be able to lower it again.
    func setWorking(_ id: SurfaceID, _ on: Bool) {
        guard let wasWorking = entries[id]?.working else { return }
        entries[id]?.working = on
        if wasWorking, !on { latchAgent(id, .completed) }
        if !wasWorking, on, entries[id]?.agentLatched == .completed { answerAgent(id) }
    }

    func endAgent(_ id: SurfaceID) {
        entries[id]?.working = false
        answerAgent(id)
    }

    func answerAgent(_ id: SurfaceID) {
        entries[id]?.agentLatched = .idle
        entries[id]?.agentSince = nil
    }

    /// Answers the whole tab: every surface in it is seen and its latches drop.
    func markSeen(tab: TabID) {
        for id in ids(in: tab) { markSeen(id) }
        residual[tab] = nil
    }

    /// A visit: surfaces `isOnScreen` accepts are seen, and latches left by closed surfaces drop.
    func visit(_ tab: TabID, isOnScreen: (SurfaceID) -> Bool) {
        for id in ids(in: tab) where isOnScreen(id) { markSeen(id) }
        residual[tab] = nil
    }

    func markSeen(_ id: SurfaceID) {
        entries[id]?.seen = true
        entries[id]?.latched = .idle
        entries[id]?.since = nil
        entries[id]?.waitingSince = nil
    }

    func dropTab(_ tab: TabID) {
        for id in ids(in: tab) { entries[id] = nil }
        residual[tab] = nil
    }

    func state(of id: SurfaceID) -> SurfaceAttention {
        entries[id].map(effective) ?? .idle
    }

    func agentState(of id: SurfaceID) -> SurfaceAttention {
        guard let entry = entries[id] else { return .idle }
        return max(entry.agentLatched, entry.working ? .working : .idle)
    }

    func isWorking(_ id: SurfaceID) -> Bool {
        entries[id]?.working == true
    }

    func agentSince(of id: SurfaceID) -> Date? {
        entries[id]?.agentSince
    }

    func state(tab: TabID) -> SurfaceAttention {
        let surfaces = entries.values.filter { $0.tab == tab }.map(effective)
        return SurfaceAttention.rollup(surfaces + [residual[tab]?.state ?? .idle])
    }

    /// A workspace's attention: its tabs folded the same way a tab folds its surfaces.
    func state(tabs ids: [TabID]) -> SurfaceAttention {
        SurfaceAttention.rollup(ids.map { state(tab: $0) })
    }

    var windowState: SurfaceAttention {
        SurfaceAttention.rollup(entries.values.map(effective) + residual.values.map(\.state))
    }

    /// When the oldest agent still waiting on you started waiting. A completion is not waiting.
    var waitingSince: Date? {
        waitingByAge.compactMap(\.since).min()
    }

    /// Everything still waiting on you, longest first. A pane that exited leaves the tab it spoke from.
    var waitingInOrder: [WaitingTarget] {
        waitingByAge.map(\.target)
    }

    private var waitingByAge: [(target: WaitingTarget, since: Date?, rank: Int)] {
        let latched = entries.compactMap { id, entry -> (WaitingTarget, Date?, Int)? in
            guard !entry.seen, entry.latched == .waiting else { return nil }
            return (.surface(id), entry.waitingSince, id.raw)
        }
        let folded = residual.compactMap { tab, value -> (WaitingTarget, Date?, Int)? in
            guard value.state == .waiting else { return nil }
            return (.tab(tab), value.waitingSince, tab.raw)
        }
        return (latched + folded)
            .sorted {
                let a = $0.1 ?? .distantFuture
                let b = $1.1 ?? .distantFuture
                return a == b ? $0.2 < $1.2 : a < b
            }
            .map { (target: $0.0, since: $0.1, rank: $0.2) }
    }

    /// How many agents are waiting on you. A residual counts: something asked, and you have not looked.
    var waitingCount: Int {
        entries.values.filter { !$0.seen && $0.latched == .waiting }.count
            + residual.values.reduce(0) { $0 + $1.waiting }
    }

    func latchAgent(_ id: SurfaceID, _ event: SurfaceAttention) {
        guard var entry = entries[id], event > entry.agentLatched else { return }
        entry.agentLatched = event
        entry.agentSince = now()
        entries[id] = entry
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
