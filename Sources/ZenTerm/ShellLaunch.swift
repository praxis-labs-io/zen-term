import Foundation
import TerminalKit

/// Builds terminal launch configs. `shell` is the ordinary pane/drawer session; `program`
/// runs a command inside a login+interactive shell that `exec`s a fresh shell when the
/// command exits — so quitting the program (`:q` in nvim, `Ctrl-D` in claude) drops back
/// to a prompt in the same pane instead of closing it. Used by the `⌘P` workspace preset.
enum ShellLaunch {
    static var userShell: String {
        GeneralConfig.current.shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Fallback cwd when none is supplied. Launched from an app bundle the process cwd is
    /// `/`, and a login shell doesn't `cd` home on its own — so an unspecified cwd would
    /// otherwise open a pane at the filesystem root. Home is the right default.
    static var defaultCWD: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The default pane/drawer session. With no configured shell this is a plain
    /// login+interactive shell (`command: nil` → the backend rewrites argv[0] to a login
    /// shell). A configured `shell` is launched explicitly, login+interactive by default
    /// (or with the user's `shell-args`), preserving login semantics on both backends.
    static func shell(cwd: URL?) -> TerminalSurfaceConfig {
        let behavior = GeneralConfig.current.terminalBehavior
        if let custom = GeneralConfig.current.shell {
            let args = GeneralConfig.current.shellArgs.isEmpty ? ["-l", "-i"] : GeneralConfig.current.shellArgs
            return TerminalSurfaceConfig(
                command: custom, args: args, workingDirectory: cwd ?? defaultCWD,
                theme: Theme.current.terminal, behavior: behavior)
        }
        return TerminalSurfaceConfig(
            workingDirectory: cwd ?? defaultCWD, theme: Theme.current.terminal, behavior: behavior)
    }

    /// Run `command` in a login+interactive shell, then `exec` a fresh one so the session
    /// survives the program exiting. `-l -i` matches how a program run from a pane sees
    /// the environment (sources profile files and `.zshrc`).
    static func program(_ command: String, cwd: URL?) -> TerminalSurfaceConfig {
        let sh = userShell
        return TerminalSurfaceConfig(
            command: sh,
            args: ["-l", "-i", "-c", "\(command); exec \(sh) -l -i"],
            workingDirectory: cwd ?? defaultCWD,
            theme: Theme.current.terminal,
            behavior: GeneralConfig.current.terminalBehavior
        )
    }
}
