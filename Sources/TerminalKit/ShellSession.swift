import Darwin

/// The process session behind one terminal surface.
///
/// Every surface's shell calls `setsid()`, so it leads its own session and every process it
/// goes on to spawn inherits that session id, whatever process group the shell parks it in.
/// That makes the session the one handle that survives job control and re-parenting, both of
/// which a `SIGHUP` aimed at the shell's own process group misses (ZEN-269).
enum ShellSession {
    /// Live pids paired with their parent, from a single `sysctl` snapshot.
    ///
    /// The table can grow between the sizing call and the fetch, which fails the fetch with
    /// ENOMEM against a buffer sized to the stale count. A silent empty result here reads
    /// downstream as "nothing to kill," so retry with headroom instead of trusting one size.
    private static func snapshot() -> [(pid: pid_t, ppid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            size += size / 4
            let count = size / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            var fetched = size
            if sysctl(&mib, 4, &procs, &fetched, nil, 0) == 0 {
                let actual = fetched / MemoryLayout<kinfo_proc>.stride
                return procs.prefix(actual).map { (pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid) }
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// Direct children of this process that lead their own session, i.e. terminal shells.
    /// An ordinary helper subprocess (a git probe) stays in our session, so it never matches.
    static func leaderChildren() -> Set<pid_t> {
        let me = getpid()
        return Set(snapshot().filter { $0.ppid == me && getsid($0.pid) == $0.pid }.map(\.pid))
    }

    /// Every live pid in `session`, never including this process or pid 1.
    static func members(of session: pid_t) -> [pid_t] {
        let me = getpid()
        return snapshot().map(\.pid).filter { $0 != me && $0 > 1 && getsid($0) == session }
    }
}
