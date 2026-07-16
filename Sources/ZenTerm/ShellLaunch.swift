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
    static func shell(cwd: URL?, env: [String: String] = [:]) -> TerminalSurfaceConfig {
        let behavior = GeneralConfig.current.terminalBehavior
        if let custom = GeneralConfig.current.shell {
            let args = GeneralConfig.current.shellArgs.isEmpty ? ["-l", "-i"] : GeneralConfig.current.shellArgs
            return TerminalSurfaceConfig(
                command: custom, args: args, workingDirectory: cwd ?? defaultCWD,
                environment: env, theme: Theme.current.terminal, behavior: behavior)
        }
        return TerminalSurfaceConfig(
            workingDirectory: cwd ?? defaultCWD, environment: env,
            theme: Theme.current.terminal, behavior: behavior)
    }

    /// Run `command` in a login+interactive shell, then `exec` a fresh one so the session
    /// survives the program exiting. `-l -i` matches how a program run from a pane sees
    /// the environment (sources profile files and `.zshrc`). A workspace recipe's `env`
    /// is injected on top, so it's visible to the launched program and the shell it leaves.
    static func program(_ command: String, cwd: URL?, env: [String: String] = [:]) -> TerminalSurfaceConfig {
        let sh = userShell
        return TerminalSurfaceConfig(
            command: sh,
            args: ["-l", "-i", "-c", "\(command); \(zshIntegrationRearm(for: sh))exec \(sh) -l -i"],
            workingDirectory: cwd ?? defaultCWD,
            environment: env,
            theme: Theme.current.terminal,
            behavior: GeneralConfig.current.terminalBehavior
        )
    }

    /// Re-arm libghostty's zsh integration for the shell the `exec` tail leaves behind (ZEN-144).
    ///
    /// libghostty injects integration by pointing `ZDOTDIR` at its own dir, and its `.zshenv`
    /// *restores* the user's `ZDOTDIR` before their rc files run — so only the shell libghostty
    /// spawned is injected, and the one we `exec` over it is not. An uninjected shell never emits
    /// OSC 7, so the pane reports its seed cwd forever: floats stop following the directory, ⌘T
    /// inherits the wrong dir, and prompt marks never fire. This restages the redirect so the
    /// `exec`'d shell is injected exactly as the first one was, mirroring `setupZsh` in
    /// libghostty's `termio/shell_integration.zig`:
    ///
    /// - `GHOSTTY_ZSH_ZDOTDIR` is set **only if** `ZDOTDIR` already is — `.zshenv` tests whether
    ///   it's *set*, not non-empty, so assigning it unconditionally would export `ZDOTDIR=""` to
    ///   users who had none instead of leaving it unset.
    /// - Nothing happens without `GHOSTTY_RESOURCES_DIR`; `GhosttyApp` skips that `setenv` when
    ///   the resource staging is missing, and an unguarded redirect would point `ZDOTDIR` at
    ///   `/shell-integration/zsh` and break rc loading outright.
    /// - Non-zsh shells are left alone: libghostty's own injection is shell-specific, and a
    ///   `ZDOTDIR` means nothing to fish or bash.
    private static func zshIntegrationRearm(for shell: String) -> String {
        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh" else { return "" }
        return "if [[ -n \"$GHOSTTY_RESOURCES_DIR\" ]]; then "
            + "if [[ -n \"${ZDOTDIR+X}\" ]]; then export GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\"; fi; "
            + "export ZDOTDIR=\"$GHOSTTY_RESOURCES_DIR/shell-integration/zsh\"; fi; "
    }
}
