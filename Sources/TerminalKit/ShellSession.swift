import Darwin

/// The process session behind one terminal surface.
///
/// Every surface's shell calls `setsid()`, so everything it spawns inherits that session id
/// whatever process group it is parked in. That makes the session the one handle surviving job
/// control and re-parenting, which a `SIGHUP` at the shell's own process group misses.
enum ShellSession {
    /// Live pids paired with their parent, from a single `sysctl` snapshot. The table can grow
    /// between the sizing call and the fetch, failing it with ENOMEM, and a silent empty result
    /// reads downstream as "nothing to kill", so retry with headroom rather than trust one size.
    private static func snapshot() -> [(pid: pid_t, ppid: pid_t, isExited: Bool)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            let count = (size + size / 4) / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            // The buffer's real size, not the headroomed byte count it was derived from: that
            // rounds up past the allocation, and telling the kernel it may write more than we
            // own is a length-contract violation held up only by xnu copying whole records.
            var fetched = count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &procs, &fetched, nil, 0) == 0 {
                let actual = fetched / MemoryLayout<kinfo_proc>.stride
                return procs.prefix(actual).map {
                    (
                        pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid,
                        isExited: $0.kp_proc.p_stat == SZOMB
                    )
                }
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// Direct children of this process that lead their own session. libghostty starts every shell
    /// under `/usr/bin/login`, which is what calls `setsid()`. An ordinary helper subprocess stays
    /// in our session, so it never matches.
    static func leaderChildren() -> Set<pid_t> {
        let me = getpid()
        return Set(
            snapshot()
                .filter { $0.ppid == me && !$0.isExited && getsid($0.pid) == $0.pid }
                .map(\.pid))
    }

    /// The sessions from `candidates` whose leader has exited: nobody is running a shell in
    /// them any more, whatever is still alive inside.
    static func orphaned(among candidates: Set<pid_t>) -> [pid_t] {
        guard !candidates.isEmpty else { return [] }  // don't walk the table to filter nothing
        let table = snapshot()
        // A failed snapshot returns empty, and empty would classify every candidate as orphaned:
        // the sweep would then SIGKILL the shell, dev server and agent of every open pane, with
        // no surface having closed. That is the ZEN-269 failure arriving through the back door.
        // A live system always has at least this process in the table, so empty never means
        // "nothing is running", only "we could not look". Sweep nothing and wait for the next
        // look (ZEN-306).
        guard !table.isEmpty else { return [] }
        let live = Set(table.filter { !$0.isExited }.map(\.pid))
        return candidates.filter { !live.contains($0) }
    }

    /// Every live pid in `session`, never including this process or pid 1.
    static func members(of session: pid_t) -> [pid_t] {
        let me = getpid()
        return snapshot().map(\.pid).filter { $0 != me && $0 > 1 && getsid($0) == session }
    }
}
