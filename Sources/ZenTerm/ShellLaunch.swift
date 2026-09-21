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

    static func program(_ command: String, cwd: URL?, env: [String: String] = [:]) -> TerminalSurfaceConfig {
        let sh = userShell
        return TerminalSurfaceConfig(
            command: sh,
            args: [
                "-l", "-i", "-c",
                "\(commandStart)\(command); \(commandFinish(for: sh))"
                    + "\(zshIntegrationRearm(for: sh))exec \(sh) -l -i",
            ],
            workingDirectory: cwd ?? defaultCWD,
            environment: env,
            fontSize: SessionFontSize.points,
            theme: Theme.current.terminal,
            behavior: GeneralConfig.current.terminalBehavior
        )
    }

    // A `-c` shell runs no prompt hook, so the program's own exit reports no OSC 133 mark of its own.
    private static let commandStart = "printf '\\033]133;C\\007'; "

    private static func commandFinish(for shell: String) -> String {
        let status = URL(fileURLWithPath: shell).lastPathComponent == "fish" ? "$status" : "$?"
        return "printf '\\033]133;D;%d\\007' \(status); "
    }

    /// libghostty's `.zshenv` restores `ZDOTDIR`, so the `exec`'d zsh needs the redirect restaged.
    private static func zshIntegrationRearm(for shell: String) -> String {
        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh" else { return "" }
        return "if [[ -n \"$GHOSTTY_RESOURCES_DIR\" ]]; then "
            + "if [[ -n \"${ZDOTDIR+X}\" ]]; then export GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\"; fi; "
            + "export ZDOTDIR=\"$GHOSTTY_RESOURCES_DIR/shell-integration/zsh\"; fi; "
    }
}
