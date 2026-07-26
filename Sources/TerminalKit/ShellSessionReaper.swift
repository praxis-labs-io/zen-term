import Darwin
import Foundation

/// Tears down the process sessions behind terminated surfaces.
///
/// `SIGTERM` first so a dev server can flush and release its port, a short grace, then
/// `SIGKILL` for whatever ignored it. libghostty already sends `SIGHUP` to the shell's own
/// process group when the surface is freed; this sweeps up everything that group never
/// covered (background jobs, children in their own process groups, `nohup`, `disown`).
public final class ShellSessionReaper {
    public static let shared = ShellSessionReaper()

    /// How long a process gets to exit on its own after `SIGTERM`.
    private static let grace: TimeInterval = 0.15

    /// How long a freed surface's session leader gets to notice its pty closed and exit. It
    /// took 45ms when measured; the window is wide enough to cover a loaded machine and is a
    /// ceiling, not a wait — the sweep runs the moment the leader goes.
    private static let orphanWindow: TimeInterval = 1.0

    /// How often that window is checked.
    private static let orphanPoll: TimeInterval = 0.02

    /// The longest a full sweep can take: wait out the leader, then one graced pass over
    /// however many sessions it found. Every session is signalled in the same pass, so this
    /// does not grow with pane count. `drain` callers size their cap from this rather than
    /// picking a literal that silently truncates the sweep.
    public static var worstCaseSweep: TimeInterval { orphanWindow + grace }

    private let queue = DispatchQueue(
        label: "com.drucial.zenterm.shell-session-reaper", qos: .userInitiated)
    private let pending = DispatchGroup()

    /// Guards `isWatching`. The watcher is process-wide, so several surfaces tearing down at
    /// once must not each start one.
    private let watchLock = NSLock()
    private var isWatching = false

    private init() {}

    /// Sweep `session` off the main thread. Safe to call for a session that is already gone.
    public func reap(session: pid_t) {
        reap(sessions: [session])
    }

    /// Sweep every session in `sessions` in ONE graced pass: one `SIGTERM` sweep over all of
    /// them, one grace period, one `SIGKILL` sweep.
    ///
    /// Load-bearing that this is a batch and not a loop of single reaps. The grace has to be
    /// waited out somewhere, and per-session waits serialize: at 0.15s each, twenty sessions
    /// took 3.07s measured, and a quit capped well below that exited having swept three of
    /// them, leaving the other seventeen panes' dev servers running — the exact bug this is
    /// here to fix (ZEN-269). Batched, twenty sessions cost the same 0.15s as one.
    public func reap(sessions: Set<pid_t>) {
        let live = sessions.filter { $0 > 1 }
        guard !live.isEmpty else { return }
        pending.enter()
        queue.async { [pending] in
            defer { pending.leave() }
            let doomed = live.flatMap { ShellSession.members(of: $0) }
            guard !doomed.isEmpty else { return }
            for pid in doomed { kill(pid, SIGTERM) }
            // Off-main by construction (see `queue`), so sleeping here blocks nothing the
            // user can see.
            Thread.sleep(forTimeInterval: Self.grace)
            for pid in live.flatMap({ ShellSession.members(of: $0) }) { kill(pid, SIGKILL) }
        }
    }

    /// Sweep the sessions a torn-down surface left behind: the ones whose leader exited when its
    /// pty closed. Waits for that exit rather than assuming it has already happened, and stops at
    /// the first sweep, so a surface closed on its own costs one round trip.
    ///
    /// It sweeps whatever is orphaned, not "this surface's" session, because nothing can say
    /// which session a surface owned (see `ShellSessionLedger`). That is the point: a live pane's
    /// leader is alive, so a live pane is never in reach.
    ///
    /// One watcher serves every caller. `takeOrphans` empties the ledger, so the first watcher
    /// claims everything and any others would spin their whole window finding nothing while
    /// parking a dispatch thread each: closing a twenty-pane workspace held twenty of them.
    public func reapOrphans() {
        watchLock.lock()
        if isWatching {
            watchLock.unlock()
            return
        }
        isWatching = true
        watchLock.unlock()

        pending.enter()
        // Its own queue, not the serial sweep queue: the wait below must not queue up behind
        // a grace period already running there.
        DispatchQueue.global(qos: .userInitiated).async { [pending] in
            defer {
                self.watchLock.lock()
                self.isWatching = false
                self.watchLock.unlock()
                pending.leave()
            }
            let deadline = Date().addingTimeInterval(Self.orphanWindow)
            while Date() < deadline {
                let orphans = ShellSessionLedger.shared.takeOrphans()
                guard orphans.isEmpty else {
                    self.reap(sessions: Set(orphans))
                    return
                }
                // Off-main by construction, so sleeping here blocks nothing the user can see.
                Thread.sleep(forTimeInterval: Self.orphanPoll)
            }
        }
    }

    /// Wait for outstanding sweeps, capped by `timeout` so a quit can never hang on a
    /// stubborn process. `completion` runs exactly once, on the main queue.
    public func drain(timeout: TimeInterval, completion: @escaping () -> Void) {
        var fired = false
        let fire = {
            guard !fired else { return }
            fired = true
            completion()
        }
        // Both paths land on main, so the `fired` check needs no further synchronization.
        pending.notify(queue: .main) { fire() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { fire() }
    }
}
