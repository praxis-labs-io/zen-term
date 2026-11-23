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
        arguments(of: pid)?.first.flatMap(programName(from:))
    }

    nonisolated static func arguments(of pid: pid_t) -> [String]? {
        guard let raw = raw(of: pid), raw.count > MemoryLayout<Int32>.size else { return nil }
        let argc = raw.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let fields = raw.dropFirst(MemoryLayout<Int32>.size).split(separator: 0)
        guard argc > 0, fields.count > 1 else { return nil }
        return fields.dropFirst().prefix(Int(argc)).map { String(decoding: $0, as: UTF8.self) }
    }

    // A login shell's argv[0] starts with `-`.
    nonisolated static func programName(from argument: String) -> String? {
        let last = argument.split(separator: "/").last.map(String.init) ?? ""
        let name = last.hasPrefix("-") ? String(last.dropFirst()) : last
        return name.isEmpty ? nil : name
    }

    // A script runs as its interpreter, so its own name is the first argument that is not a flag.
    nonisolated static func scriptName(in arguments: [String]) -> String? {
        guard let program = arguments.first.flatMap(programName(from:)),
            interpreters.contains(withoutVersion(program.lowercased()))
        else { return nil }
        for argument in arguments.dropFirst() {
            if inlineCodeFlags.contains(argument) { return nil }
            if !argument.hasPrefix("-") { return programName(from: argument) }
        }
        return nil
    }

    nonisolated static func commandName(from arguments: [String]) -> String? {
        scriptName(in: arguments) ?? arguments.first.flatMap(programName(from:))
    }

    // `python3.12` runs as itself, not as `python`.
    nonisolated static func withoutVersion(_ program: String) -> String {
        String(program.reversed().drop { $0.isNumber || $0 == "." }.reversed())
    }

    private nonisolated static let interpreters: Set<String> = [
        "python", "bash", "sh", "zsh", "dash", "node", "ruby", "perl",
    ]

    // `bash -c` and `perl -e` run the code that follows, so no argument names a script.
    private nonisolated static let inlineCodeFlags: Set<String> = ["-c", "-e"]
}
