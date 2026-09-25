import Foundation

/// Turns a stream of pushed signals into the few transitions worth acting on. Main-thread only.
final class AgentStateTracker {
    /// Long enough to outlast a dropped spinner frame, short enough that a real turn end still feels immediate.
    static let idleHold: TimeInterval = 0.7

    private struct Entry {
        var published: AgentSignalState = .idle
        var pendingIdleSince: Date?
    }

    private var entries: [SurfaceID: Entry] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The state to publish, or nil when nothing changed and nothing is worth doing.
    func publish(_ id: SurfaceID, _ outcome: AgentStateEngine.Outcome) -> AgentSignalState? {
        guard let next = outcome.state else { return nil }
        var entry = entries[id] ?? Entry()
        defer { entries[id] = entry }

        guard next != entry.published else {
            entry.pendingIdleSince = nil
            return nil
        }

        if entry.published == .working, next == .idle, outcome == .fallback {
            let started = entry.pendingIdleSince ?? now()
            entry.pendingIdleSince = started
            guard now().timeIntervalSince(started) >= Self.idleHold else { return nil }
        }

        entry.pendingIdleSince = nil
        entry.published = next
        return next
    }

    func state(of id: SurfaceID) -> AgentSignalState {
        entries[id]?.published ?? .idle
    }

    func isHoldingIdle(_ id: SurfaceID) -> Bool {
        entries[id]?.pendingIdleSince != nil
    }

    func drop(_ id: SurfaceID) {
        entries[id] = nil
    }
}
