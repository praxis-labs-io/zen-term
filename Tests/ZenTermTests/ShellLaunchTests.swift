import TerminalKit
import XCTest

@testable import ZenTerm

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

    func test_program_wrapsCommandInLoginShellThatReExecs() {
        withConfig(shell: "/bin/zsh")
        let config = ShellLaunch.program("nvim .", cwd: URL(fileURLWithPath: "/work"))
        XCTAssertEqual(config.command, "/bin/zsh")
        XCTAssertEqual(
            config.args,
            [
                "-l", "-i", "-c",
                "printf '\\033]133;C\\007'; nvim .; printf '\\033]133;D;%d\\007' $?; "
                    + "if [[ -n \"$GHOSTTY_RESOURCES_DIR\" ]]; then "
                    + "if [[ -n \"${ZDOTDIR+X}\" ]]; then export GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\"; fi; "
                    + "export ZDOTDIR=\"$GHOSTTY_RESOURCES_DIR/shell-integration/zsh\"; fi; "
                    + "exec /bin/zsh -l -i",
            ])
        XCTAssertEqual(config.workingDirectory, URL(fileURLWithPath: "/work"))
    }

    func test_program_doesNotRearmIntegration_forANonZshShell() {
        withConfig(shell: "/usr/local/bin/fish")
        let config = ShellLaunch.program("nvim .", cwd: nil)
        XCTAssertEqual(
            config.args,
            [
                "-l", "-i", "-c",
                "printf '\\033]133;C\\007'; nvim .; printf '\\033]133;D;%d\\007' $status; "
                    + "exec /usr/local/bin/fish -l -i",
            ])
    }

    func test_program_marksTheProgramsExit_soAnEarlyExitNeedsNoBusyPoll() {
        withConfig(shell: "/bin/zsh")
        let script = ShellLaunch.program("claude --resume", cwd: nil).args.last
        XCTAssertEqual(
            script?.hasPrefix(
                "printf '\\033]133;C\\007'; claude --resume; printf '\\033]133;D;%d\\007' $?; "),
            true, "the exit mark carries the program's own status, right where it exits")
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
