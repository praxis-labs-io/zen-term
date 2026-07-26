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

    private init() {}

    func record(_ sessions: Set<pid_t>) {
        lock.lock()
        defer { lock.unlock() }
        known.formUnion(sessions)
    }

    /// The recorded sessions whose leader has exited, dropped from the ledger as they are
    /// handed out so two teardowns racing each other can't both sweep the same one.
    func takeOrphans() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        let orphans = ShellSession.orphaned(among: known)
        known.subtract(orphans)
        return orphans
    }
}
