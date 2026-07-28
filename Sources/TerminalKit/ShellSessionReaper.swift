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

    /// The longest quit will wait for the shells to go before leaving anyway.
    ///
    /// A cap, not a wait: leaders exit about 45ms after their pty closes, so an ordinary quit
    /// spends roughly that plus one `grace` here. It is only reached by a foreground child that
    /// is slow to die, and reaching it costs one pause on the way out rather than a leaked dev
    /// server. It can never hang the quit.
    public static let quitSweepBudget: TimeInterval = 3.0

    /// How often the quit drain re-checks whether the shells have gone.
    private static let quitPoll: TimeInterval = 0.02

    private let queue = DispatchQueue(
        label: "com.drucial.zenterm.shell-session-reaper", qos: .userInitiated)
    private let pending = DispatchGroup()

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

    /// Sweep every session whose leader has exited, right now.
    ///
    /// Called by the ledger the moment one of its watched leaders goes, and by a teardown just
    /// after it frees a surface. It sweeps whatever is orphaned, not "this surface's" session,
    /// because nothing can say which session a surface owned (see `ShellSessionLedger`). That is
    /// the point: a live pane's leader is alive, so a live pane is never in reach.
    ///
    /// Cheap to call speculatively. `takeOrphans` hands each session out once, so overlapping
    /// callers cannot both sweep the same one, and finding nothing costs one process-table walk.
    public func sweepOrphans() {
        // Held across the take so the group is never transiently empty between a session
        // leaving the ledger and its sweep entering: a quit draining in that gap would see
        // idle and exit with the signals still unsent.
        pending.enter()
        defer { pending.leave() }
        let orphans = ShellSessionLedger.shared.takeOrphans()
        guard !orphans.isEmpty else { return }
        reap(sessions: Set(orphans))
    }

    /// Sweep the sessions a torn-down surface left behind.
    ///
    /// The leader usually has not exited yet when this runs, and that is fine: it is armed with
    /// its own watch, which fires the moment it goes. This is the immediate look for anything
    /// already orphaned, not the mechanism.
    public func reapOrphans() {
        DispatchQueue.global(qos: .userInitiated).async { self.sweepOrphans() }
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

    /// Hold quit open until every shell this app started has gone and been swept, capped by
    /// `timeout`. `completion` runs exactly once, on the main queue.
    ///
    /// Waiting on the ledger emptying rather than on outstanding work is what makes this
    /// correct at quit. The leaders have not exited yet when the last surface is freed, so
    /// there is nothing in flight to wait for: a drain that only watched for idle would see
    /// none and let the process go before a single signal went out, which is the leak on the
    /// most ordinary way to close the app (ZEN-269, ZEN-306).
    public func drainAllSessions(timeout: TimeInterval, completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            while !ShellSessionLedger.shared.isEmpty, Date() < deadline {
                // Off-main by construction, so sleeping here blocks nothing the user can see.
                Thread.sleep(forTimeInterval: Self.quitPoll)
            }
            let left = max(0, deadline.timeIntervalSinceNow)
            DispatchQueue.main.async { self.drain(timeout: left, completion: completion) }
        }
    }
}
