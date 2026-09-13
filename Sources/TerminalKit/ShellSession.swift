import Darwin

// Every shell calls `setsid()`, so its session id survives job control and re-parenting.
enum ShellSession {
    private static func snapshot() -> [(pid: pid_t, ppid: pid_t, isExited: Bool)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            let count = (size + size / 4) / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
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

    static func leaderChildren() -> Set<pid_t> {
        let me = getpid()
        return Set(
            snapshot()
                .filter { $0.ppid == me && !$0.isExited && getsid($0.pid) == $0.pid }
                .map(\.pid))
    }

    // A failed snapshot reads empty, which must sweep nothing rather than kill every open pane.
    static func orphaned(among candidates: Set<pid_t>) -> [pid_t] {
        guard !candidates.isEmpty else { return [] }
        let table = snapshot()
        guard !table.isEmpty else { return [] }
        let live = Set(table.filter { !$0.isExited }.map(\.pid))
        return candidates.filter { !live.contains($0) }
    }

    static func members(of session: pid_t) -> [pid_t] {
        let me = getpid()
        return snapshot().map(\.pid).filter { $0 != me && $0 > 1 && getsid($0) == session }
    }
}
