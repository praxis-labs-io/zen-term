import Foundation

// What the person has unsent at each pane's prompt, and the messages queued for it in order. App-wide, main-thread only.
final class PaneDrafts {
    struct Message {
        let isTask: Bool
        let setsDraftAside: () -> Bool
        let isBlocked: () -> Bool
        let deliver: (_ overDraft: Bool) -> Void
        let drop: (_ reason: String) -> Void
    }

    // A nil length is text ZenTerm could not count, or a cursor it lost, which only Return or a clearing key ends.
    private struct Draft {
        var length: Int?
        var endsInBackslash = false
    }

    // So a message does not land in the prompt just as the person starts typing into it.
    static let quiet: TimeInterval = 2
    static let draftWait: TimeInterval = 60
    // The agent puts a set-aside draft back as its message submits, so the next message waits for that.
    static let draftRestorePause: TimeInterval = 2
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
    private var restoredAt: [SurfaceID: Date] = [:]
    private var scheduled: [SurfaceID: Date] = [:]

    func typed(_ edit: DraftEdit, into surface: SurfaceID) {
        guard edit != .submit else { return submit(surface) }
        lastKeys[surface] = now()
        switch edit {
        case .add(let text):
            drafts[surface] = Draft(
                length: (drafts[surface] ?? Draft(length: 0)).length.map { $0 + text.count },
                endsInBackslash: text.hasSuffix("\\"))
        case .addUnknown:
            drafts[surface] = Draft(length: nil)
        case .stash:
            if drafts[surface] == nil { drafts[surface] = Draft(length: nil) } else { endDraft(surface) }
        case .move:
            drafts[surface]?.length = nil
        case .removeOne:
            drafts[surface]?.endsInBackslash = false
            guard let length = drafts[surface]?.length else { return }
            if length > 1 { drafts[surface]?.length = length - 1 } else { endDraft(surface) }
        case .removeUnknown:
            drafts[surface]?.length = nil
            drafts[surface]?.endsInBackslash = false
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
            restoredAt[surface] = nil
            queues.removeValue(forKey: surface)?.forEach { $0.drop("its pane closed") }
        }
    }

    // Claude Code reads a backslash before Return as a newline, so that Return sends nothing.
    private func submit(_ surface: SurfaceID) {
        guard drafts[surface]?.endsInBackslash != true else {
            lastKeys[surface] = now()
            drafts[surface]?.endsInBackslash = false
            return
        }
        lastKeys[surface] = nil
        drafts[surface] = nil
        after(0) { [weak self] in self?.drain(surface) }
    }

    private func endDraft(_ surface: SurfaceID) {
        drafts[surface] = nil
        drain(surface)
    }

    private func quietAt(_ surface: SurfaceID) -> Date {
        lastKeys[surface].map { $0.addingTimeInterval(Self.quiet) } ?? .distantPast
    }

    // Nil while only the person can release the queue: a draft that its agent cannot set aside.
    private func releaseAt(_ surface: SurfaceID, for head: Message) -> Date? {
        let restored = restoredAt[surface] ?? .distantPast
        guard drafts[surface] != nil else { return max(quietAt(surface), restored) }
        guard head.setsDraftAside() else { return nil }
        return max(draftWaitEnds(surface), restored)
    }

    private func draftWaitEnds(_ surface: SurfaceID) -> Date {
        lastKeys[surface].map { $0.addingTimeInterval(Self.draftWait) } ?? .distantPast
    }

    // The blocked cap counts only time the queue could have delivered in, so a draft never spends it.
    private func drain(_ surface: SurfaceID) {
        guard let first = queues[surface]?.first else { return }
        guard let releaseAt = releaseAt(surface, for: first) else {
            blockedSince[surface] = nil
            let recheckIn = draftWaitEnds(surface).timeIntervalSince(now())
            if recheckIn > 0 { schedule(surface, in: recheckIn) }
            return
        }
        let waitFor = releaseAt.timeIntervalSince(now())
        guard waitFor <= 0 else {
            blockedSince[surface] = nil
            return schedule(surface, in: waitFor)
        }
        let overDraft = drafts[surface] != nil
        while let head = queues[surface]?.first {
            guard head.isBlocked() else {
                blockedSince[surface] = nil
                queues[surface]?.removeFirst()
                head.deliver(overDraft)
                guard overDraft else { continue }
                restoredAt[surface] = now().addingTimeInterval(Self.draftRestorePause)
                return queues[surface]?.isEmpty == false ? drain(surface) : endQueue(surface)
            }
            let since = blockedSince[surface] ?? now()
            blockedSince[surface] = since
            guard now() >= since.addingTimeInterval(Self.longestBlockedHold) else {
                return schedule(surface, in: Self.blockedRecheck)
            }
            queues[surface]?.removeFirst()
            head.drop("its agent stayed blocked")
            if overDraft { return queues[surface]?.isEmpty == false ? drain(surface) : endQueue(surface) }
        }
        endQueue(surface)
    }

    private func endQueue(_ surface: SurfaceID) {
        queues[surface] = nil
        blockedSince[surface] = nil
    }

    // Only the earliest pending drain runs, so a sooner release is never stuck behind a later one.
    private func schedule(_ surface: SurfaceID, in delay: TimeInterval) {
        let due = now().addingTimeInterval(delay)
        if let pending = scheduled[surface], pending <= due { return }
        scheduled[surface] = due
        after(delay) { [weak self] in
            guard let self, self.scheduled[surface] == due else { return }
            self.scheduled[surface] = nil
            self.drain(surface)
        }
    }
}
