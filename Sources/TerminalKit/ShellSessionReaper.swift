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
