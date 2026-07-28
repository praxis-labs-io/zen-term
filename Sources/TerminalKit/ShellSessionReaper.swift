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

    /// How long quit lets the shells exit gracefully before sweeping them outright.
    ///
    /// Not a leak/hang trade: whatever has not gone by then is swept anyway, so reaching this
    /// costs a pause on the way out and nothing survives it either way. Leaders exit about 45ms
    /// after their pty closes, so an ordinary quit never approaches it. It bounds the graceful
    /// wait only; the sweep that follows always gets `sweepReserve` on top.
    public static let quitSweepBudget: TimeInterval = 3.0

    /// Held back from `quitSweepBudget` for the sweep itself: one full graced pass plus slack for
    /// the two process-table walks around it.
    ///
    /// Load-bearing. Spending the whole budget on the leader wait leaves `drain` a timeout of
    /// about zero, so quit replies the instant `reap` has sent `SIGTERM` and the process exits
    /// before the `SIGKILL` pass ever runs: anything that ignores `SIGTERM` survives the quit,
    /// which is the leak the budget exists to prevent.
    private static var sweepReserve: TimeInterval { grace + 0.1 }

    /// How often the quit drain re-checks whether the shells have gone.
    private static let quitPoll: TimeInterval = 0.02

    /// How long a burst of leader exits is gathered before sweeping.
    ///
    /// Restores the quantization the old 20ms poll gave for free. Every watched leader fires its
    /// own source, and one sweep per fire would put one graced `reap` pass per leader on the
    /// serial queue: twenty panes closing together would serialize twenty 150ms passes, and the
    /// tail would still be queued, unsignalled, when quit's budget ran out. That is verbatim what
    /// `reap(sessions:)`'s batch exists to prevent.
    private static let coalesce: TimeInterval = 0.02

    private let queue = DispatchQueue(
        label: "com.drucial.zenterm.shell-session-reaper", qos: .userInitiated)
    private let pending = DispatchGroup()

    /// Guards `sweepScheduled`, which collapses a burst of leader exits into one sweep.
    private let coalesceLock = NSLock()
    private var sweepScheduled = false

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
    ///
    /// Internal on purpose: it is a synchronous process-table walk that `takeOrphans` documents
    /// as never-main, so it is not something a consumer outside `TerminalKit` should be able to
    /// reach for.
    func sweepOrphans() {
        // Held across the take so the group is never transiently empty between a session
        // leaving the ledger and its sweep entering: a quit draining in that gap would see
        // idle and exit with the signals still unsent.
        pending.enter()
        defer { pending.leave() }
        let orphans = ShellSessionLedger.shared.takeOrphans()
        guard !orphans.isEmpty else { return }
        reap(sessions: Set(orphans))
    }

    /// Gather a burst of leader exits into one sweep, so a window's worth of panes closing
    /// together costs one graced pass rather than one per pane. Called by every watched leader's
    /// exit; the first arrival schedules the sweep and the rest join it.
    func scheduleSweep() {
        coalesceLock.lock()
        if sweepScheduled {
            coalesceLock.unlock()
            return
        }
        sweepScheduled = true
        coalesceLock.unlock()

        // Entered here rather than inside the sweep: a quit draining between now and the sweep
        // running must see work outstanding, not an idle group.
        pending.enter()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.coalesce) {
            defer { self.pending.leave() }
            // Cleared before sweeping, not after, so a leader exiting during the sweep schedules
            // the next one instead of being swallowed.
            self.coalesceLock.lock()
            self.sweepScheduled = false
            self.coalesceLock.unlock()
            self.sweepOrphans()
        }
    }

    /// Sweep the sessions a torn-down surface left behind.
    ///
    /// The leader usually has not exited yet when this runs, and that is fine: it is armed with
    /// its own watch, which fires the moment it goes. This is the immediate look for anything
    /// already orphaned, not the mechanism.
    ///
    /// **`pending.enter()` runs on the caller's thread, before the dispatch.** A teardown calls
    /// this and a drain can follow on the very next statement; if the enter happened inside the
    /// async block the group would still be empty at that point, the drain would report done, and
    /// the caller would check for survivors before a single signal went out. Empty means "nothing
    /// in flight", which is indistinguishable from "nothing has started yet" (ZEN-306, and see
    /// `docs/swift-conventions.md`).
    public func reapOrphans() {
        pending.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.pending.leave() }
            self.sweepOrphans()
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

    /// Hold quit open until every shell this app started has gone and been swept, capped by
    /// `timeout`. `completion` runs exactly once, on the main queue.
    ///
    /// Waiting on the ledger emptying rather than on outstanding work is what makes this
    /// correct at quit. The leaders have not exited yet when the last surface is freed, so
    /// there is nothing in flight to wait for: a drain that only watched for idle would see
    /// none and let the process go before a single signal went out, which is the leak on the
    /// most ordinary way to close the app (ZEN-269, ZEN-306).
    public func drainForQuit(timeout: TimeInterval, completion: @escaping () -> Void) {
        // The budget bounds the wait for leaders. The sweep is always given `sweepReserve` on
        // top, so the SIGKILL half can never be cut off by a leader that took its time.
        let waitDeadline = Date().addingTimeInterval(max(0, timeout - Self.sweepReserve))
        pending.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.pending.leave() }
            // Give the shells the chance to go on their own first, so the ordinary quit is the
            // graceful one: leaders exit about 45ms after their pty closes and their sessions
            // sweep through the normal watch path.
            while ShellSessionLedger.shared.count > 0, Date() < waitDeadline {
                // Off-main by construction, so sleeping here blocks nothing the user can see.
                Thread.sleep(forTimeInterval: Self.quitPoll)
            }
            // Whatever is still recorded belongs to a surface that is already torn down, so its
            // leader is merely slow, never a live pane. Sweep it outright instead of waiting out
            // a budget that cannot help: only a leader exiting empties the ledger, so a shell
            // that is never going to notice its pty would otherwise cost the full hang AND still
            // leave its dev server running (ZEN-306).
            let stragglers = ShellSessionLedger.shared.takeAll()
            if !stragglers.isEmpty { self.reap(sessions: Set(stragglers)) }
            let left = Self.sweepReserve + max(0, waitDeadline.timeIntervalSinceNow)
            DispatchQueue.main.async { self.drain(timeout: left, completion: completion) }
        }
    }
}
