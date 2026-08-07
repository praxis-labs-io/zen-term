import TerminalKit
import XCTest

@testable import ZenTerm

/// Unit tests for `ShellLaunch` — the launch-config builder behind ⌘P workspaces and every
/// pane/drawer (ZEN-143). Covers the custom-shell / shell-args branch, the login+interactive
/// `program` wrapper that keeps a pane alive after the program exits, env merge, and the
/// home-is-the-default-cwd rule.
final class ShellLaunchTests: XCTestCase {
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private func withConfig(shell: String? = nil, shellArgs: [String] = []) {
        var config = GeneralConfig.builtIn
        config.shell = shell
        config.shellArgs = shellArgs
        GeneralConfig.setCurrentForTesting(config)
    }

    // MARK: shell()

    func test_shell_defaultsToLoginShell_whenNoCustomShell() {
        withConfig(shell: nil)
        let config = ShellLaunch.shell(cwd: URL(fileURLWithPath: "/tmp"))
        XCTAssertNil(config.command, "no configured shell → backend rewrites argv[0] to a login shell")
        XCTAssertEqual(config.args, [])
        XCTAssertEqual(config.workingDirectory, URL(fileURLWithPath: "/tmp"))
    }

    func test_shell_usesCustomShellWithLoginInteractiveArgsByDefault() {
        withConfig(shell: "/bin/bash")
        let config = ShellLaunch.shell(cwd: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(config.command, "/bin/bash")
        XCTAssertEqual(config.args, ["-l", "-i"], "a configured shell keeps login+interactive semantics")
    }

    func test_shell_honorsCustomShellArgs() {
        withConfig(shell: "/bin/bash", shellArgs: ["-x", "--norc"])
        let config = ShellLaunch.shell(cwd: nil)
        XCTAssertEqual(config.command, "/bin/bash")
        XCTAssertEqual(config.args, ["-x", "--norc"], "user shell-args override the login+interactive default")
    }

    func test_shell_defaultsCwdToHome_whenNil() {
        withConfig(shell: nil)
        XCTAssertEqual(ShellLaunch.shell(cwd: nil).workingDirectory, home)
    }

    func test_shell_mergesEnv() {
        withConfig(shell: nil)
        let config = ShellLaunch.shell(cwd: nil, env: ["ZEN_PANE": "7"])
        XCTAssertEqual(config.environment["ZEN_PANE"], "7")
    }

    // MARK: program()

    func test_program_wrapsCommandInLoginShellThatReExecs() {
        // Pin an explicit zsh: `userShell` falls back to the tester's ambient `$SHELL`, which
        // would make the tail (and so this assertion) machine-dependent.
        withConfig(shell: "/bin/zsh")
        let config = ShellLaunch.program("nvim .", cwd: URL(fileURLWithPath: "/work"))
        XCTAssertEqual(config.command, "/bin/zsh")
        // The `; exec …` tail keeps the pane alive with a fresh shell after the program quits,
        // and re-arms libghostty's ZDOTDIR redirect so that shell keeps integration (ZEN-144).
        XCTAssertEqual(
            config.args,
            [
                "-l", "-i", "-c",
                "nvim .; if [[ -n \"$GHOSTTY_RESOURCES_DIR\" ]]; then "
                    + "if [[ -n \"${ZDOTDIR+X}\" ]]; then export GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\"; fi; "
                    + "export ZDOTDIR=\"$GHOSTTY_RESOURCES_DIR/shell-integration/zsh\"; fi; "
                    + "exec /bin/zsh -l -i",
            ])
        XCTAssertEqual(config.workingDirectory, URL(fileURLWithPath: "/work"))
    }

    /// The re-arm is zsh-specific — libghostty's injection is per-shell and `ZDOTDIR` means
    /// nothing to fish. A fish user keeps the plain tail rather than a broken redirect.
    func test_program_doesNotRearmIntegration_forANonZshShell() {
        withConfig(shell: "/usr/local/bin/fish")
        let config = ShellLaunch.program("nvim .", cwd: nil)
        XCTAssertEqual(config.args, ["-l", "-i", "-c", "nvim .; exec /usr/local/bin/fish -l -i"])
    }

    func test_program_injectsEnvAndDefaultsCwdToHome() {
        withConfig(shell: nil)
        let config = ShellLaunch.program("claude", cwd: nil, env: ["FOO": "bar"])
        XCTAssertEqual(config.environment["FOO"], "bar")
        XCTAssertEqual(config.workingDirectory, home)
    }

    func test_userShell_prefersConfiguredShell() {
        withConfig(shell: "/usr/local/bin/fish")
        XCTAssertEqual(ShellLaunch.userShell, "/usr/local/bin/fish")
    }
}
