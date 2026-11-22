import Darwin

// A sysctl read of kernel memory, cheap enough for the main thread.
enum ProcessArguments {
    // KERN_PROCARGS2: argc, then the executable path, then argv, each NUL-terminated.
    nonisolated static func raw(of pid: pid_t) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    // argv[0], not the executable: Claude's own installer runs a binary named for its version.
    nonisolated static func programName(of pid: pid_t) -> String? {
        guard let raw = raw(of: pid), raw.count > MemoryLayout<Int32>.size else { return nil }
        let argc = raw.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let fields = raw.dropFirst(MemoryLayout<Int32>.size).split(separator: 0)
        guard argc > 0, fields.count > 1 else { return nil }
        return name(String(decoding: fields[1], as: UTF8.self))
    }

    // A login shell's argv[0] starts with `-`.
    private nonisolated static func name(_ argument: String) -> String? {
        let last = argument.split(separator: "/").last.map(String.init) ?? ""
        let name = last.hasPrefix("-") ? String(last.dropFirst()) : last
        return name.isEmpty ? nil : name
    }
}
