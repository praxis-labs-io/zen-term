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

    private let queue = DispatchQueue(
        label: "com.drucial.zenterm.shell-session-reaper", qos: .userInitiated)
    private let pending = DispatchGroup()

    private init() {}

    /// Sweep `session` off the main thread. Safe to call for a session that is already gone.
    public func reap(session: pid_t) {
        guard session > 1 else { return }
        pending.enter()
        queue.async { [pending] in
            defer { pending.leave() }
            let first = ShellSession.members(of: session)
            guard !first.isEmpty else { return }
            for pid in first { kill(pid, SIGTERM) }
            // Off-main by construction (see `queue`), so sleeping here blocks nothing the
            // user can see.
            Thread.sleep(forTimeInterval: Self.grace)
            for pid in ShellSession.members(of: session) { kill(pid, SIGKILL) }
        }
    }

    /// Sweep the sessions a torn-down surface left behind: the ones whose leader exited when its
    /// pty closed. Waits for that exit rather than assuming it has already happened, and stops at
    /// the first sweep, so a surface closed on its own costs one round trip.
    ///
    /// It sweeps whatever is orphaned, not "this surface's" session, because nothing can say
    /// which session a surface owned (see `ShellSessionLedger`). That is the point: a live pane's
    /// leader is alive, so a live pane is never in reach.
    public func reapOrphans() {
        pending.enter()
        // Its own queue, not the serial sweep queue: several panes closing at once would
        // otherwise queue their waits end to end behind each other's grace period.
        DispatchQueue.global(qos: .userInitiated).async { [pending] in
            defer { pending.leave() }
            let deadline = Date().addingTimeInterval(Self.orphanWindow)
            while Date() < deadline {
                let orphans = ShellSessionLedger.shared.takeOrphans()
                guard orphans.isEmpty else {
                    orphans.forEach { self.reap(session: $0) }
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
