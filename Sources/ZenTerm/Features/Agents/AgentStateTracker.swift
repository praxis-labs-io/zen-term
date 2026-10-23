import Foundation

// Main-thread only.
final class AgentStateTracker {
    // Long enough to outlast a dropped spinner frame, short enough that a real turn end still feels immediate.
    static let idleHold: TimeInterval = 0.7

    private struct Entry {
        var title = ""
        var progress = AgentRules.clearedProgress
        var published: AgentSignalState = .idle
        var pendingIdleSince: Date?
        var reportsProgress = false
    }

    private var entries: [SurfaceID: Entry] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func noteTitle(_ title: String, of id: SurfaceID) {
        entries[id, default: Entry()].title = title
    }

    func noteProgress(_ progress: String, of id: SurfaceID) {
        entries[id, default: Entry()].progress = progress
        entries[id]?.reportsProgress = true
    }

    func title(of id: SurfaceID) -> String { entries[id]?.title ?? "" }

    func progress(of id: SurfaceID) -> String { entries[id]?.progress ?? AgentRules.clearedProgress }

    func publish(_ id: SurfaceID, _ outcome: AgentStateEngine.Outcome) -> AgentSignalState? {
        let next = outcome.state
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

    // Claude clears its progress at launch, so an agent that reports none has its progress turned off.
    func reportsProgress(_ id: SurfaceID) -> Bool {
        entries[id]?.reportsProgress == true
    }

    func isHoldingIdle(_ id: SurfaceID) -> Bool {
        entries[id]?.pendingIdleSince != nil
    }

    func drop(_ id: SurfaceID) {
        entries[id] = nil
    }
}
