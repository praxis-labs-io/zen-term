import Darwin
import Foundation

/// The shell sessions this app has started, and which of them nobody is running any more.
///
/// **Nothing here attributes a session to a surface**, because a surface cannot name its own
/// shell: libghostty forks it asynchronously under a setuid `/usr/bin/login` the kernel will not
/// describe to us, so a surface that guesses can adopt a sibling's session and SIGKILL a live
/// pane's work when it closes. Instead, freeing a surface closes its pty and takes that session's
/// leader down, and a session whose leader has exited is by definition nobody's live pane.
///
/// Each leader is watched for its own exit rather than polled for within a window. There is no
/// correct duration to guess, because a shell waiting on a foreground child exits when that child
/// does, and a leader slower than the window was never swept at all.
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

    /// How many recorded sessions are still waiting for their leader to go. Zero means nothing is
    /// outstanding, and a count that stops falling means nothing more is going to happen.
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
    /// A fire is only a prompt to look: the sweep re-checks the process table and matches sessions
    /// with `getsid`, so a stale or recycled pid costs one wasted look and can never reach a live
    /// pane's session. Fires are coalesced through `scheduleSweep` because a window's panes close
    /// together, and one sweep per fire would leave the tail unsignalled when quit gave up.
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
    /// libghostty forks the shell well past `ghostty_surface_new`'s return, so a single snapshot
    /// at start time reliably finds nothing. One sampler serves every surface: a later start
    /// extends the deadline rather than launching a second walk of the process table.
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
    /// path. Calling this while a pane is open would SIGKILL that pane's session: the
    /// leader-exited test guarding `takeOrphans` is what normally keeps a live pane out of reach.
    func takeAll() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(known)
        known.removeAll()
        watches.values.forEach { $0.cancel() }
        watches.removeAll()
        return all
    }

    /// The recorded sessions whose leader has exited, dropped from the ledger as they are handed
    /// out so two teardowns racing each other can't both sweep the same one. No caller is on the
    /// main thread.
    ///
    /// The process-table walk runs *outside* the lock, since holding it across each ~0.3ms walk
    /// stalled a main-thread `record` behind a queue of them by 5.6ms. Two invariants keep the
    /// narrower critical section safe: hand-out stays exclusive, because the subtraction from
    /// `known` is one atomic step under the lock; and the snapshot never judges a session newer
    /// than itself, because candidates are read before the walk, so a session recorded mid-walk
    /// waits for the next look rather than being matched against a table from before its shell
    /// forked, which would sweep a live pane.
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
