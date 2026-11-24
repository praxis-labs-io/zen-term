import Foundation

// What the person has unsent at each pane's prompt, and the messages queued for it in order. App-wide, main-thread only.
final class PaneDrafts {
    struct Message {
        let isBlocked: () -> Bool
        let deliver: () -> Void
        let drop: (_ reason: String) -> Void
    }

    // So a message does not land in the prompt just as the person starts typing into it.
    static let quiet: TimeInterval = 2
    static let blockedRecheck: TimeInterval = 1
    static let longestBlockedHold: TimeInterval = 600

    var now: () -> Date = Date.init
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private var lastKeys: [SurfaceID: Date] = [:]
    private var drafts: Set<SurfaceID> = []
    private var queues: [SurfaceID: [Message]] = [:]
    private var blockedSince: [SurfaceID: Date] = [:]
    private var scheduled: Set<SurfaceID> = []

    func typed(_ edit: DraftEdit, into surface: SurfaceID) {
        switch edit {
        case .write:
            lastKeys[surface] = now()
            drafts.insert(surface)
        case .clear:
            lastKeys[surface] = now()
            drafts.remove(surface)
            drain(surface)
        case .submit:
            lastKeys[surface] = nil
            drafts.remove(surface)
            after(0) { [weak self] in self?.drain(surface) }
        case .none:
            lastKeys[surface] = now()
        }
    }

    func isHolding(_ surface: SurfaceID) -> Bool {
        queues[surface] != nil || drafts.contains(surface) || now() < quietAt(surface)
    }

    func queue(_ surface: SurfaceID, _ message: Message) {
        queues[surface, default: []].append(message)
        drain(surface)
    }

    func panesClosed(_ surfaces: [SurfaceID]) {
        for surface in surfaces {
            lastKeys[surface] = nil
            drafts.remove(surface)
            blockedSince[surface] = nil
            queues.removeValue(forKey: surface)?.forEach { $0.drop("its pane closed") }
        }
    }

    private func quietAt(_ surface: SurfaceID) -> Date {
        lastKeys[surface].map { $0.addingTimeInterval(Self.quiet) } ?? .distantPast
    }

    // The blocked cap counts only time the queue could have delivered in, so a draft never spends it.
    private func drain(_ surface: SurfaceID) {
        guard queues[surface] != nil else { return }
        let quietFor = quietAt(surface).timeIntervalSince(now())
        guard !drafts.contains(surface), quietFor <= 0 else {
            blockedSince[surface] = nil
            if !drafts.contains(surface) { schedule(surface, in: quietFor) }
            return
        }
        while let head = queues[surface]?.first {
            guard head.isBlocked() else {
                blockedSince[surface] = nil
                queues[surface]?.removeFirst()
                head.deliver()
                continue
            }
            let since = blockedSince[surface] ?? now()
            blockedSince[surface] = since
            guard now() >= since.addingTimeInterval(Self.longestBlockedHold) else {
                return schedule(surface, in: Self.blockedRecheck)
            }
            queues[surface]?.removeFirst()
            head.drop("its agent stayed blocked")
        }
        queues[surface] = nil
        blockedSince[surface] = nil
    }

    private func schedule(_ surface: SurfaceID, in delay: TimeInterval) {
        guard scheduled.insert(surface).inserted else { return }
        after(delay) { [weak self] in
            self?.scheduled.remove(surface)
            self?.drain(surface)
        }
    }
}
