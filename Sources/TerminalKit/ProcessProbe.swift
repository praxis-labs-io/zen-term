import Darwin

/// Kernel probe for "is a foreground command running in this terminal" — used to tell an
/// idle prompt from a shell running something, so the chrome only warns before closing real
/// work. Backend-agnostic (pty fd + pid only), so it stays below the terminal seam.
public enum ProcessProbe {
    /// True when the pty's foreground process group is NOT the shell itself — i.e. the shell
    /// has handed the terminal to a foreground command (vim, a server, a pipeline). An idle
    /// prompt keeps the shell in the foreground (`group == shellPid`), and a *backgrounded*
    /// job (`cmd &`, an async-prompt helper) never becomes the foreground group — so unlike a
    /// "has any child" check, this doesn't over-report either.
    ///
    /// `masterFd` is the pty master (SwiftTerm's `LocalProcess.childfd`); `shellPid` is the
    /// shell, which is its own process-group leader (so its pgid equals its pid).
    public static func hasForegroundJob(masterFd: Int32, shellPid: pid_t) -> Bool {
        guard masterFd >= 0, shellPid > 0 else { return false }
        let group = tcgetpgrp(masterFd)
        return group > 0 && group != shellPid
    }
}
