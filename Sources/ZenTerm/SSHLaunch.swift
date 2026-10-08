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

    static func arguments(host: SSHHostID, controlPath: URL, form: Form) -> [String] {
        let options = [
            "-o", "ControlMaster=auto",
            "-o", controlPathOption(controlPath),
            "-o", "ControlPersist=\(controlPersistSeconds)",
        ]
        switch form {
        case .loginShell: return options + ["-t", "--", host.alias, loginShellCommand]
        case .plain: return options + ["--", host.alias]
        }
    }

    // Programs on the host, Claude's progress among them, see the same terminal a local pane gives them.
    static var loginShellCommand: String {
        let identity = TerminalIdentity.environment.sorted { $0.key < $1.key }.map {
            remoteWord("\($0.key)=\($0.value)")
        }
        return (["exec", "env"] + identity + [#""$SHELL""#, "-l"]).joined(separator: " ")
    }

    // Single quotes, since a csh login shell parses the command too.
    static func remoteWord(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func checkArguments(host: SSHHostID, controlPath: URL) -> [String] {
        [
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", controlPathOption(controlPath),
            "-O", "check",
            "--", host.alias,
        ]
    }

    static func masterPID(in output: String) -> pid_t? {
        guard let start = output.range(of: "pid=")?.upperBound else { return nil }
        return pid_t(output[start...].prefix(while: \.isNumber))
    }

    private static func controlPathOption(_ controlPath: URL) -> String {
        "ControlPath=\"\(controlPath.path.replacingOccurrences(of: "%", with: "%%"))\""
    }

    static var workingDirectory: URL { ShellLaunch.defaultCWD }

    // libghostty replaces a cleared title with the pane's pwd, and a host pane's is the local folder ssh starts in.
    static var clearedTitle: String { workingDirectory.path }

    static func config(
        host: SSHHostID, controlPath: URL, form: Form, env: [String: String] = [:], backingScale: CGFloat? = nil
    ) -> TerminalSurfaceConfig {
        var environment = env
        environment["TERM"] = "xterm-256color"
        return TerminalSurfaceConfig(
            command: executable, args: arguments(host: host, controlPath: controlPath, form: form),
            workingDirectory: workingDirectory, environment: environment,
            fontSize: SessionFontSize.points, theme: Theme.current.terminal,
            behavior: GeneralConfig.current.terminalBehavior, tracksBusy: false, backingScale: backingScale)
    }

    private static func digest(of host: SSHHostID) -> String {
        SHA256.hash(data: Data(host.alias.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
