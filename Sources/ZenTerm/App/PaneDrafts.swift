import Foundation

// What the person has unsent at each pane's prompt, and the messages queued for it in order. App-wide, main-thread only.
final class PaneDrafts {
    struct Message {
        let isTask: Bool
        let isBlocked: () -> Bool
        let deliver: () -> Void
        let drop: (_ reason: String) -> Void
    }

    // A nil length is text ZenTerm could not count, which only Return or a clearing key ends.
    private struct Draft {
        var length: Int?
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
    private var drafts: [SurfaceID: Draft] = [:]
    private var queues: [SurfaceID: [Message]] = [:]
    private var blockedSince: [SurfaceID: Date] = [:]
    private var scheduled: Set<SurfaceID> = []

    func typed(_ edit: DraftEdit, into surface: SurfaceID) {
        guard edit != .submit else {
            lastKeys[surface] = nil
            drafts[surface] = nil
            return after(0) { [weak self] in self?.drain(surface) }
        }
        lastKeys[surface] = now()
        switch edit {
        case .add(let text):
            drafts[surface] = Draft(length: (drafts[surface] ?? Draft(length: 0)).length.map { $0 + text.count })
        case .addUnknown:
            drafts[surface] = Draft(length: nil)
        case .removeOne:
            guard let length = drafts[surface]?.length else { return }
            if length > 1 { drafts[surface]?.length = length - 1 } else { endDraft(surface) }
        case .removeUnknown:
            if drafts[surface] != nil { drafts[surface]?.length = nil }
        case .clear:
            endDraft(surface)
        case .submit, .none:
            break
        }
    }

    func isHolding(_ surface: SurfaceID) -> Bool {
        queues[surface] != nil || drafts[surface] != nil || now() < quietAt(surface)
    }

    func hasQueuedTask(for surface: SurfaceID) -> Bool {
        queues[surface]?.contains(where: \.isTask) == true
    }

    func queue(_ surface: SurfaceID, _ message: Message) {
        queues[surface, default: []].append(message)
        drain(surface)
    }

    func panesClosed(_ surfaces: [SurfaceID]) {
        for surface in surfaces {
            lastKeys[surface] = nil
            drafts[surface] = nil
            blockedSince[surface] = nil
            queues.removeValue(forKey: surface)?.forEach { $0.drop("its pane closed") }
        }
    }

    private func endDraft(_ surface: SurfaceID) {
        drafts[surface] = nil
        drain(surface)
    }

    private func quietAt(_ surface: SurfaceID) -> Date {
        lastKeys[surface].map { $0.addingTimeInterval(Self.quiet) } ?? .distantPast
    }

    // The blocked cap counts only time the queue could have delivered in, so a draft never spends it.
    private func drain(_ surface: SurfaceID) {
        guard queues[surface] != nil else { return }
        let quietFor = quietAt(surface).timeIntervalSince(now())
        guard drafts[surface] == nil, quietFor <= 0 else {
            blockedSince[surface] = nil
            if drafts[surface] == nil { schedule(surface, in: quietFor) }
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
