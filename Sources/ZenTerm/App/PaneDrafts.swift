import Foundation

// What the person has unsent at each pane's prompt, and the messages held until they send it. App-wide, main-thread only.
final class PaneDrafts {
    // So a message does not land in the prompt just as the person starts typing into it.
    static let quiet: TimeInterval = 2

    var now: () -> Date = Date.init
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private var lastKeys: [SurfaceID: Date] = [:]
    private var drafts: Set<SurfaceID> = []
    private var held: [SurfaceID: [() -> Void]] = [:]

    func typed(_ edit: DraftEdit, into surface: SurfaceID) {
        switch edit {
        case .write:
            lastKeys[surface] = now()
            drafts.insert(surface)
        case .clear:
            lastKeys[surface] = now()
            drafts.remove(surface)
            release(surface)
        case .submit:
            lastKeys[surface] = nil
            drafts.remove(surface)
            DispatchQueue.main.async { [weak self] in self?.flush(surface) }
        case .none:
            lastKeys[surface] = now()
        }
    }

    func isHolding(_ surface: SurfaceID) -> Bool {
        held[surface] != nil || drafts.contains(surface) || now() < quietAt(surface)
    }

    func queue(_ surface: SurfaceID, _ deliver: @escaping () -> Void) {
        held[surface, default: []].append(deliver)
        release(surface)
    }

    func panesClosed(_ surfaces: [SurfaceID]) {
        for surface in surfaces {
            lastKeys[surface] = nil
            drafts.remove(surface)
            held[surface] = nil
        }
    }

    private func quietAt(_ surface: SurfaceID) -> Date {
        lastKeys[surface].map { $0.addingTimeInterval(Self.quiet) } ?? .distantPast
    }

    private func release(_ surface: SurfaceID) {
        guard held[surface] != nil, !drafts.contains(surface) else { return }
        let wait = quietAt(surface).timeIntervalSince(now())
        guard wait > 0 else { return flush(surface) }
        after(wait) { [weak self] in self?.release(surface) }
    }

    private func flush(_ surface: SurfaceID) {
        held.removeValue(forKey: surface)?.forEach { $0() }
    }
}
