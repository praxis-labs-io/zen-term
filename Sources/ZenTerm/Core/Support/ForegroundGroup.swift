import Darwin

// Sysctl and `getsid` reads, cheap enough for the main thread.
enum ForegroundGroup {
    // A pane's shell leads its session, or is the child of the `login` that does; a job it runs is neither.
    nonisolated static func isShell(_ group: pid_t) -> Bool {
        let session = getsid(group)
        guard session > 0 else { return false }
        return session == group || parent(of: group) == session
    }

    private nonisolated static func parent(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
