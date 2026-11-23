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
        guard case .script(let name) = invocation(of: arguments) else { return nil }
        return name
    }

    nonisolated static func commandName(from arguments: [String]) -> String? {
        scriptName(in: arguments) ?? arguments.first.flatMap(programName(from:))
    }

    // A shell started at a prompt (`zsh`, `nix develop`, `sudo -s`) is a prompt too, not a job.
    nonisolated static func isInteractiveShell(_ arguments: [String]) -> Bool {
        guard let program = arguments.first.flatMap(programName(from:)),
            shells.contains(withoutVersion(program.lowercased()))
        else { return false }
        return invocation(of: arguments) == .interactive
    }

    private enum Invocation: Equatable {
        case notAnInterpreter, script(String), inlineCode, interactive, unknown
    }

    private nonisolated static func invocation(of arguments: [String]) -> Invocation {
        guard let program = arguments.first.flatMap(programName(from:)) else { return .notAnInterpreter }
        let interpreter = withoutVersion(program.lowercased())
        guard shells.contains(interpreter) || interpreters.contains(interpreter) else { return .notAnInterpreter }
        let codeLetters = inlineCodeLetters[interpreter] ?? []
        var skipsValue = false
        var namesModule = false
        for argument in arguments.dropFirst() {
            if namesModule { return programName(from: argument).map(Invocation.script) ?? .unknown }
            if skipsValue { skipsValue = false; continue }
            if argument == "-m", interpreter == "python" { namesModule = true; continue }
            if argument == "--" { continue }
            if argument.hasPrefix("--") {
                let flag = String(argument.prefix { $0 != "=" })
                if longInlineCodeFlags.contains(flag) { return .inlineCode }
                skipsValue = valueFlags.contains(argument)
                continue
            }
            if argument.hasPrefix("-"), argument.count > 1 {
                if argument.dropFirst().contains(where: codeLetters.contains) { return .inlineCode }
                skipsValue = valueFlags.contains(argument)
                continue
            }
            guard argument.contains("/") || argument.contains("."), let name = programName(from: argument) else {
                return .unknown
            }
            return .script(name)
        }
        return .interactive
    }

    // `python3.12` runs as itself, not as `python`.
    nonisolated static func withoutVersion(_ program: String) -> String {
        String(program.reversed().drop { $0.isNumber || $0 == "." }.reversed())
    }

    private nonisolated static let shells: Set<String> = ["bash", "sh", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    private nonisolated static let interpreters: Set<String> = ["python", "node", "ruby", "perl"]

    // `bash -lc` and `node -p` run the code that follows, so no argument names a script.
    private nonisolated static let inlineCodeLetters: [String: Set<Character>] = [
        "bash": ["c"], "sh": ["c"], "zsh": ["c"], "dash": ["c"], "fish": ["c"], "ksh": ["c"], "tcsh": ["c"],
        "csh": ["c"], "python": ["c"], "perl": ["e", "E"], "ruby": ["e"], "node": ["e", "p"],
    ]

    private nonisolated static let longInlineCodeFlags: Set<String> = ["--eval", "--print", "--command"]

    // The argument after these is their value (`python -W ignore`, `bash --rcfile`), never the script.
    private nonisolated static let valueFlags: Set<String> = [
        "-o", "-O", "-W", "-X", "-I", "-r", "--rcfile", "--init-file", "--require",
    ]
}
