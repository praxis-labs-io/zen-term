import Foundation
import TerminalKit

enum ShellLaunch {
    static var userShell: String {
        GeneralConfig.current.shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// An app bundle's cwd is `/`, and a login shell doesn't `cd` home on its own.
    static var defaultCWD: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func newSessionCWD(focused: URL?) -> URL? {
        GeneralConfig.current.tabInheritCWD ? focused : nil
    }

    static func shell(cwd: URL?, env: [String: String] = [:]) -> TerminalSurfaceConfig {
        let behavior = GeneralConfig.current.terminalBehavior
        if let custom = GeneralConfig.current.shell {
            let args = GeneralConfig.current.shellArgs.isEmpty ? ["-l", "-i"] : GeneralConfig.current.shellArgs
            return TerminalSurfaceConfig(
                command: custom, args: args, workingDirectory: cwd ?? defaultCWD,
                environment: env, fontSize: SessionFontSize.points,
                theme: Theme.current.terminal, behavior: behavior)
        }
        return TerminalSurfaceConfig(
            workingDirectory: cwd ?? defaultCWD, environment: env,
            fontSize: SessionFontSize.points, theme: Theme.current.terminal, behavior: behavior)
    }

    static func program(
        _ command: String, cwd: URL?, env: [String: String] = [:], exitClosesPane: Bool = false,
        marksExit: Bool = false
    ) -> TerminalSurfaceConfig {
        let sh = userShell
        let tail = exitClosesPane ? "" : "\(zshIntegrationRearm(for: sh))exec \(sh) -l -i"
        let title = titling(command, for: sh)
        let script: String
        if !(exitClosesPane || marksExit || isAgent(command)) {
            script = "\(title)\(command); \(tail)"
        } else if let hook = exitHook(for: sh) {
            script = "\(title)\(onceMark)\(hook)\(commandStart)\(command)\n__zen_mark $?; \(tail)"
        } else {
            script = "\(title)\(commandStart)\(command); \(commandFinish(for: sh))\(tail)"
        }
        return TerminalSurfaceConfig(
            command: sh,
            args: ["-l", "-i", "-c", script],
            workingDirectory: cwd ?? defaultCWD,
            environment: env,
            fontSize: SessionFontSize.points,
            theme: Theme.current.terminal,
            behavior: GeneralConfig.current.terminalBehavior
        )
    }

    // Only an agent's or a run pane's exit is tracked, and marking every program would toast when nvim quits.
    private static func isAgent(_ command: String) -> Bool {
        AgentRoster.agentName(launching: command, listed: GeneralConfig.current.listedAgents) != nil
    }

    // A `-c` shell runs no preexec hook, so nothing titles the pane while the command runs.
    private static func titling(_ command: String, for shell: String) -> String {
        let title = String(
            command.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) })
        return "printf '\\033]2;%s\\007' \(singleQuoted(cutToTitleLimit(title), for: shell)); "
    }

    // libghostty ignores an OSC 2 title of 256 bytes or more, which a command with an absolute path easily reaches.
    private static let titleByteLimit = 255

    private static func cutToTitleLimit(_ title: String) -> String {
        guard title.utf8.count > titleByteLimit else { return title }
        let ellipsis = "\u{2026}"
        let budget = titleByteLimit - ellipsis.utf8.count
        var fitted = ""
        var bytes = 0
        for character in title {
            bytes += character.utf8.count
            guard bytes <= budget else { break }
            fitted.append(character)
        }
        return fitted + ellipsis
    }

    // fish reads `\\` and `\'` as escapes inside single quotes, where a POSIX shell takes every byte literally.
    private static func singleQuoted(_ text: String, for shell: String) -> String {
        guard URL(fileURLWithPath: shell).lastPathComponent == "fish" else {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return "'" + escaped + "'"
    }

    // A `-c` shell runs no prompt hook, so the program's own exit reports no OSC 133 mark of its own.
    private static let commandStart = "printf '\\033]133;C\\007'; "

    private static func commandFinish(for shell: String) -> String {
        let status = URL(fileURLWithPath: shell).lastPathComponent == "fish" ? "$status" : "$?"
        return "printf '\\033]133;D;%d\\007' \(status); "
    }

    // Both the inline mark and the exit hook call it, and only the first prints.
    private static let onceMark =
        "__zen_mark() { [ -n \"${__zen_marked-}\" ] || { __zen_marked=1; printf '\\033]133;D;%d\\007' \"$1\"; }; "
        + "return \"$1\"; }; "

    // A builtin `exit` skips the inline mark, so a POSIX shell also marks on exit, chained onto any EXIT trap the rc set.
    private static func exitHook(for shell: String) -> String? {
        let chainedTrap = "trap '__zen_mark $?; eval \"$__zen_prev\"' EXIT; "
        let bashChain = "eval \"set -- $(trap -p EXIT)\"; __zen_prev=${3-}; set --; \(chainedTrap)"
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh": return "__zen_exit_mark() { __zen_mark $?; }; zshexit_functions+=(__zen_exit_mark); "
        case "bash": return bashChain
        case "sh": return "if [ -n \"${BASH_VERSION-}\" ]; then \(bashChain)fi; "
        case "ksh": return "__zen_prev=$(trap -p EXIT); \(chainedTrap)"
        case "dash": return ""
        default: return nil
        }
    }

    /// libghostty's `.zshenv` restores `ZDOTDIR`, so the `exec`'d zsh needs the redirect restaged.
    private static func zshIntegrationRearm(for shell: String) -> String {
        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh" else { return "" }
        return "if [[ -n \"$GHOSTTY_RESOURCES_DIR\" ]]; then "
            + "if [[ -n \"${ZDOTDIR+X}\" ]]; then export GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\"; fi; "
            + "export ZDOTDIR=\"$GHOSTTY_RESOURCES_DIR/shell-integration/zsh\"; fi; "
    }
}
