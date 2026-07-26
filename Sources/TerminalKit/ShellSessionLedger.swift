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
final class ShellSessionLedger {
    static let shared = ShellSessionLedger()

    private let lock = NSLock()
    private var known: Set<pid_t> = []

    /// Guards the sampler. Separate from `lock` so a running sample never holds up a sweep.
    private let sampleLock = NSLock()
    private var sampleDeadline: Date?

    private init() {}

    func record(_ sessions: Set<pid_t>) {
        lock.lock()
        defer { lock.unlock() }
        known.formUnion(sessions)
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
        return orphans
    }
}
