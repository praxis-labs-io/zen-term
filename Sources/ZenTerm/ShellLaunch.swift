import Foundation
import TerminalKit

/// Builds terminal launch configs. `shell` is the ordinary pane/drawer session; `program`
/// runs a command inside a login+interactive shell that `exec`s a fresh shell when the
/// command exits — so quitting the program (`:q` in nvim, `Ctrl-D` in claude) drops back
/// to a prompt in the same pane instead of closing it. Used by the `⌘P` workspace preset.
enum ShellLaunch {
    static var userShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    /// A plain login+interactive shell (`command: nil` → the backend rewrites argv[0] to
    /// a login shell), the default pane/drawer session.
    static func shell(cwd: URL?) -> TerminalSurfaceConfig {
        TerminalSurfaceConfig(workingDirectory: cwd, theme: Theme.rosePineMoon)
    }

    /// Run `command` in a login+interactive shell, then `exec` a fresh one so the session
    /// survives the program exiting. `-l -i` matches how a program run from a pane sees
    /// the environment (sources profile files and `.zshrc`).
    static func program(_ command: String, cwd: URL?) -> TerminalSurfaceConfig {
        let sh = userShell
        return TerminalSurfaceConfig(
            command: sh,
            args: ["-l", "-i", "-c", "\(command); exec \(sh) -l -i"],
            workingDirectory: cwd,
            theme: Theme.rosePineMoon
        )
    }
}
