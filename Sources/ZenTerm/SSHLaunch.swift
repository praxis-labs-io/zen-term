import CryptoKit
import Foundation
import TerminalKit

// A host pane's launch: ssh sharing one ControlMaster connection per host, with no local shell around it.
enum SSHLaunch {
    enum Form: Equatable {
        case loginShell
        // ssh refuses a command-line command beside a host's own `RemoteCommand`.
        case plain
    }

    static let executable = "/usr/bin/ssh"

    // ssh binds `<path>.<16 chars>` first, and a path past this fails only after the login succeeds.
    static let controlPathBudget = 86

    static let controlPersistSeconds = 60

    static var socketDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZenTerm", isDirectory: true)
            .appendingPathComponent("ssh", isDirectory: true)
    }

    static var fallbackDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zenterm-ssh", isDirectory: true)
    }

    static func controlPath(
        for host: SSHHostID, in directory: URL = socketDirectory, fallback: URL = fallbackDirectory,
        pid: Int32 = getpid()
    ) -> URL {
        let name = "\(pid)-\(digest(of: host))"
        let preferred = directory.appendingPathComponent(name)
        guard preferred.path.utf8.count > controlPathBudget else { return preferred }
        return fallback.appendingPathComponent(name)
    }

    static func arguments(host: SSHHostID, controlPath: URL) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", controlPathOption(controlPath),
            "-o", "ControlPersist=\(controlPersistSeconds)",
            "--", host.name,
        ]
    }

    static func checkArguments(host: SSHHostID, controlPath: URL) -> [String] {
        [
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", controlPathOption(controlPath),
            "-O", "check",
            "--", host.name,
        ]
    }

    static func masterPID(in output: String) -> pid_t? {
        guard let start = output.range(of: "pid=")?.upperBound else { return nil }
        return pid_t(output[start...].prefix(while: \.isNumber))
    }

    private static func controlPathOption(_ controlPath: URL) -> String {
        "ControlPath=\"\(controlPath.path.replacingOccurrences(of: "%", with: "%%"))\""
    }

    static func config(host: SSHHostID, controlPath: URL, env: [String: String] = [:]) -> TerminalSurfaceConfig {
        var environment = env
        environment["TERM"] = "xterm-256color"
        return TerminalSurfaceConfig(
            command: executable, args: arguments(host: host, controlPath: controlPath),
            workingDirectory: ShellLaunch.defaultCWD, environment: environment,
            fontSize: SessionFontSize.points, theme: Theme.current.terminal,
            behavior: GeneralConfig.current.terminalBehavior, tracksBusy: false)
    }

    private static func digest(of host: SSHHostID) -> String {
        SHA256.hash(data: Data(host.name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
