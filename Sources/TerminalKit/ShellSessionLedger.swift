import Darwin
import Foundation

/// The shell sessions this app has started, and which of them nobody is running any more.
///
/// A surface cannot name its own shell. libghostty forks it asynchronously, some way past
/// `ghostty_surface_new`'s return, under a setuid `/usr/bin/login` whose command line and
/// environment the kernel will not show us — so neither fork order, nor first sighting, nor a
/// tag planted in the environment separates this surface's session from the pane next door's.
/// A surface that guesses can adopt a sibling's session and SIGKILL a live pane's shell, dev
/// server and agent when it closes (ZEN-269).
///
/// So nothing here attributes a session to a surface. Freeing a surface closes its pty, which
/// takes that session's leader down with it, and a session whose leader has exited is by
/// definition nobody's live pane. Teardown sweeps exactly those, which reaches every leftover
/// of the surface that just went away and can never reach a pane that is still running.
///
/// Every recorded leader is watched for its own exit rather than polled for within a window.
/// The window was a wall-clock guess at how long a leader takes to notice its pty closed, and
/// a leader that took longer was never swept at all: nothing rescheduled a look, so on the last
/// pane its dev server outlived the close (ZEN-306). There is no correct duration to guess,
/// because a shell waiting on a foreground child exits when that child does. These leaders are
/// our own direct children, so the kernel will tell us the moment each one goes.
final class ShellSessionLedger {
    static let shared = ShellSessionLedger()

    private let lock = NSLock()
    private var known: Set<pid_t> = []

    /// One kqueue watch per recorded leader, armed while it is provably alive and torn down
    /// when its session is swept. Keyed by pid so a leader recorded twice (the start sampler
    /// and the teardown snapshot both see it) is watched once.
    private var watches: [pid_t: DispatchSourceProcess] = [:]

    /// Guards the sampler. Separate from `lock` so a running sample never holds up a sweep.
    private let sampleLock = NSLock()
    private var sampleDeadline: Date?

    private init() {}

    /// How many recorded sessions are still waiting for their leader to go. The quit drain
    /// watches this: `takeOrphans` removes sessions as it hands them out, so zero means nothing
    /// is outstanding, and a count that stops falling means nothing more is going to happen.
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

    /// Arm a watch for one leader's exit.
    ///
    /// `leaderChildren` only returns leaders that were alive in its snapshot, so the watch is
    /// always armed against a live process. If the leader exits in the gap between that
    /// snapshot and this call the source still fires, because an unreaped child stays in the
    /// table as a zombie. A fire is only a prompt to look: the sweep re-checks the process
    /// table through `takeOrphans` and matches sessions with `getsid`, so a stale or recycled
    /// pid costs one wasted look and can never reach a live pane's session.
    ///
    /// Fires go through `scheduleSweep`, not straight to a sweep. A window's panes close
    /// together and their leaders exit milliseconds apart, so one sweep per fire would put one
    /// graced `reap` pass per pane on the reaper's serial queue and the tail would still be
    /// waiting, unsignalled, when quit gave up.
    private func makeWatch(for pid: pid_t) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit,
            queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { ShellSessionReaper.shared.scheduleSweep() }
        source.resume()
        return source
    }

    /// Watch for new shell sessions for `duration`, checking every `interval`.
    ///
    /// libghostty forks the shell well past `ghostty_surface_new`'s return and `setsid()` then
    /// runs in the child, so a single snapshot taken at start time reliably finds nothing. What
    /// this records is surface-independent, so one sampler serves every surface starting at
    /// once: a later start extends the deadline rather than launching a second walk of the
    /// process table.
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

    /// Every recorded session, emptied out, whether or not its leader has exited.
    ///
    /// **Only valid once every surface has been torn down**, which is true exactly on the quit
    /// path. The leader-exited test that guards `takeOrphans` exists to keep a live pane out of
    /// reach; when no pane is left alive there is nothing to protect, and a leader still running
    /// at that point is a shell that has not noticed its pty yet, not somebody's work. Calling
    /// this while a pane is open would SIGKILL that pane's session, which is the ZEN-269 bug.
    func takeAll() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(known)
        known.removeAll()
        watches.values.forEach { $0.cancel() }
        watches.removeAll()
        return all
    }

    /// The recorded sessions whose leader has exited, dropped from the ledger as they are
    /// handed out so two teardowns racing each other can't both sweep the same one.
    ///
    /// The process-table walk deliberately runs inside the lock: reading and subtracting have
    /// to be one atomic step, or two teardowns both see the same orphan and one sweeps a
    /// session the other already took. No caller is on the main thread. Don't narrow this.
    func takeOrphans() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        let orphans = ShellSession.orphaned(among: known)
        known.subtract(orphans)
        for pid in orphans {
            watches.removeValue(forKey: pid)?.cancel()
        }
        return orphans
    }
}
