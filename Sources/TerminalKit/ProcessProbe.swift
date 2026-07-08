import Darwin

/// Kernel probe for "does this process have children" — used to tell a shell
/// running a foreground command (or a backgrounded job) from an idle prompt.
/// Backend-agnostic and pid-only, so it stays below the terminal seam.
public enum ProcessProbe {
    /// True when `pid` has at least one child process. `pid <= 0` → false.
    public static func hasChildren(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var slot = pid_t(0)
        let size = Int32(MemoryLayout<pid_t>.size)
        let filled = proc_listchildpids(pid, &slot, size)
        return filled > 0
    }
}
