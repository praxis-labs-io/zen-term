import Darwin
import Foundation

// Never ties a session to a surface: a guess could adopt a sibling's session and kill a live pane.
final class ShellSessionLedger {
    static let shared = ShellSessionLedger()

    private let lock = NSLock()
    private var known: Set<pid_t> = []

    private var watches: [pid_t: DispatchSourceProcess] = [:]

    private let sampleLock = NSLock()
    private var sampleDeadline: Date?

    private init() {}

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return known.count
    }

    func record(_ sessions: Set<pid_t>) {
        lock.lock()
        let fresh = sessions.subtracting(known)
        known.formUnion(sessions)
        for pid in fresh {
            watches[pid] = makeWatch(for: pid)
        }
        lock.unlock()
    }

    private func makeWatch(for pid: pid_t) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit,
            queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { ShellSessionReaper.shared.scheduleSweep() }
        source.resume()
        return source
    }

    // libghostty forks the shell after `ghostty_surface_new` returns, so one snapshot finds nothing.
    func sample(for duration: TimeInterval, every interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        sampleLock.lock()
        if let existing = sampleDeadline {
            sampleDeadline = max(existing, deadline)
            sampleLock.unlock()
            return
        }
        sampleDeadline = deadline
        sampleLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            while true {
                self.record(ShellSession.leaderChildren())
                Thread.sleep(forTimeInterval: interval)
                self.sampleLock.lock()
                guard let until = self.sampleDeadline, Date() < until else {
                    self.sampleDeadline = nil
                    self.sampleLock.unlock()
                    return
                }
                self.sampleLock.unlock()
            }
        }
    }

    // Only safe once every surface is torn down; otherwise it kills a live pane's session.
    func takeAll() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(known)
        known.removeAll()
        watches.values.forEach { $0.cancel() }
        watches.removeAll()
        return all
    }

    // Candidates are read before the walk so a session recorded mid-walk is never judged against it.
    func takeOrphans() -> [pid_t] {
        lock.lock()
        let candidates = known
        lock.unlock()
        let exited = ShellSession.orphaned(among: candidates)
        guard !exited.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }
        let orphans = exited.filter { known.contains($0) }
        known.subtract(orphans)
        for pid in orphans {
            watches.removeValue(forKey: pid)?.cancel()
        }
        return orphans
    }
}
