import Darwin

// Sysctl and `getsid` reads, cheap enough for the main thread.
enum ForegroundGroup {
    struct Processes: Sendable {
        var session: @Sendable (pid_t) -> pid_t
        var parent: @Sendable (pid_t) -> pid_t?
        var command: @Sendable (pid_t) -> String?
    }

    nonisolated static let system = Processes(
        session: { getsid($0) }, parent: { info(of: $0)?.kp_eproc.e_ppid }, command: command(of:))

    // A pane's shell leads its session, or is the child of the `login` that does; a job it runs is neither.
    nonisolated static func isShell(_ group: pid_t, in processes: Processes = system) -> Bool {
        let session = processes.session(group)
        guard session > 0 else { return false }
        if session == group { return true }
        return processes.parent(group) == session && processes.command(session) == "login"
    }

    private nonisolated static func info(of pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    // `p_comm`, since a root-owned `login`'s arguments are not readable by the app.
    private nonisolated static func command(of pid: pid_t) -> String? {
        guard var info = info(of: pid) else { return nil }
        return withUnsafeBytes(of: &info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
