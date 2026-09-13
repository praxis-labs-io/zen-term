import Darwin
import Foundation

/// Kills what a closed surface's shell session left behind: `SIGTERM`, a short grace, then `SIGKILL`.
public final class ShellSessionReaper {
    public static let shared = ShellSessionReaper()

    private static let grace: TimeInterval = 0.15

    /// How long quit waits for shells to exit on their own before sweeping them.
    public static let quitSweepBudget: TimeInterval = 3.0

    // Without this reserve the leader wait eats the budget and quit exits before the `SIGKILL` pass.
    private static var sweepReserve: TimeInterval { grace + 0.1 }

    private static let quitPoll: TimeInterval = 0.02

    // One sweep per leader exit would serialize a graced pass per pane on the queue.
    private static let coalesce: TimeInterval = 0.02

    private let queue = DispatchQueue(
        label: "com.drucial.zenterm.shell-session-reaper", qos: .userInitiated)
    private let pending = DispatchGroup()

    private let coalesceLock = NSLock()
    private var sweepScheduled = false

    private init() {}

    /// Sweeps `session` off the main thread. Safe for a session that is already gone.
    public func reap(session: pid_t) {
        reap(sessions: [session])
    }

    /// Sweeps every session in one graced pass. Per-session passes serialize and outlast quit's budget.
    public func reap(sessions: Set<pid_t>) {
        let live = sessions.filter { $0 > 1 }
        guard !live.isEmpty else { return }
        pending.enter()
        queue.async { [pending] in
            defer { pending.leave() }
            let doomed = live.flatMap { ShellSession.members(of: $0) }
            guard !doomed.isEmpty else { return }
            for pid in doomed { kill(pid, SIGTERM) }
            Thread.sleep(forTimeInterval: Self.grace)
            for pid in live.flatMap({ ShellSession.members(of: $0) }) { kill(pid, SIGKILL) }
        }
    }

    // Synchronous process-table walk; never call it on main.
    func sweepOrphans() {
        pending.enter()
        defer { pending.leave() }
        let orphans = ShellSessionLedger.shared.takeOrphans()
        guard !orphans.isEmpty else { return }
        reap(sessions: Set(orphans))
    }

    func scheduleSweep() {
        coalesceLock.lock()
        if sweepScheduled {
            coalesceLock.unlock()
            return
        }
        sweepScheduled = true
        coalesceLock.unlock()

        pending.enter()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.coalesce) {
            defer { self.pending.leave() }
            self.coalesceLock.lock()
            self.sweepScheduled = false
            self.coalesceLock.unlock()
            self.sweepOrphans()
        }
    }

    /// Sweeps sessions whose leader has exited, off the main thread. A `drain` right after it waits for it.
    public func reapOrphans() {
        pending.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.pending.leave() }
            self.sweepOrphans()
        }
    }

    /// Waits for outstanding sweeps, up to `timeout`. `completion` runs once, on main.
    public func drain(timeout: TimeInterval, completion: @escaping () -> Void) {
        var fired = false
        let fire = {
            guard !fired else { return }
            fired = true
            completion()
        }
        pending.notify(queue: .main) { fire() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { fire() }
    }

    /// Waits until every recorded shell has exited and been swept, up to `timeout`. `completion` runs
    /// once, on main. Call only after every surface is torn down.
    public func drainForQuit(timeout: TimeInterval, completion: @escaping () -> Void) {
        let waitDeadline = Date().addingTimeInterval(max(0, timeout - Self.sweepReserve))
        pending.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.pending.leave() }
            while ShellSessionLedger.shared.count > 0, Date() < waitDeadline {
                Thread.sleep(forTimeInterval: Self.quitPoll)
            }
            let stragglers = ShellSessionLedger.shared.takeAll()
            if !stragglers.isEmpty { self.reap(sessions: Set(stragglers)) }
            let left = Self.sweepReserve + max(0, waitDeadline.timeIntervalSinceNow)
            DispatchQueue.main.async { self.drain(timeout: left, completion: completion) }
        }
    }
}
