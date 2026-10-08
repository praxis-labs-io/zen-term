import TerminalKit
import XCTest

@testable import ZenTerm

final class SSHLaunchTests: XCTestCase {
    private let host = SSHHostID(alias: "devbox")
    private let fallback = URL(fileURLWithPath: "/tmp/fallback", isDirectory: true)

    override func setUp() {
        super.setUp()
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    private func directory(makingPathBytes total: Int) -> URL {
        let name = "12345-\(String(repeating: "0", count: 8))"
        let padding = total - "/".count - name.count - "/".count
        return URL(fileURLWithPath: "/" + String(repeating: "d", count: padding), isDirectory: true)
    }

    func test_aPlainLaunch_givesEachControlOptionOnce_beforeTheHost_withNoVerboseFlag() {
        let path = URL(fileURLWithPath: "/Users/me/Library/Application Support/ZenTerm/ssh/1-abcdef12")

        let args = SSHLaunch.arguments(host: host, controlPath: path, form: .plain)

        XCTAssertEqual(
            args,
            [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\"/Users/me/Library/Application Support/ZenTerm/ssh/1-abcdef12\"",
                "-o", "ControlPersist=60",
                "--", "devbox",
            ])
        XCTAssertFalse(args.contains("-v"))
    }

    func test_aLoginShellLaunch_asksForATerminal_andRunsTheCommandAfterTheHost() {
        let path = URL(fileURLWithPath: "/tmp/1-ab")

        let args = SSHLaunch.arguments(host: host, controlPath: path, form: .loginShell)

        XCTAssertEqual(
            args,
            SSHLaunch.arguments(host: host, controlPath: path, form: .plain).dropLast(2)
                + ["-t", "--", "devbox", SSHLaunch.loginShellCommand])
    }

    func test_theLoginShellCommand_namesThisTerminal_andExecsTheUsersLoginShell() throws {
        let version = try XCTUnwrap(TerminalIdentity.environment["TERM_PROGRAM_VERSION"])

        XCTAssertEqual(
            SSHLaunch.loginShellCommand,
            #"exec env 'COLORTERM=truecolor' 'TERM_PROGRAM=ghostty' 'TERM_PROGRAM_VERSION=\#(version)' "$SHELL" -l"#)
    }

    func test_aRemoteWord_survivesAQuoteInside() {
        XCTAssertEqual(SSHLaunch.remoteWord("it's"), #"'it'\''s'"#)
    }

    func test_aPercentInThePath_isEscapedSoSSHDoesNotExpandIt() {
        let args = SSHLaunch.arguments(
            host: host, controlPath: URL(fileURLWithPath: "/tmp/100%/1-ab"), form: .loginShell)

        XCTAssertTrue(args.contains("ControlPath=\"/tmp/100%%/1-ab\""))
    }

    func test_theConfigRunsSSHDirectly_asXterm256color_withoutBusyTracking() {
        let config = SSHLaunch.config(
            host: host, controlPath: URL(fileURLWithPath: "/tmp/1-ab"), form: .plain, env: ["ZEN_SOCK": "/tmp/nav"])

        XCTAssertEqual(config.command, "/usr/bin/ssh")
        XCTAssertEqual(config.args.last, "devbox")
        XCTAssertEqual(config.environment["TERM"], "xterm-256color")
        XCTAssertEqual(config.environment["ZEN_SOCK"], "/tmp/nav")
        XCTAssertFalse(config.tracksBusy)
    }

    func test_theConfigCarriesTheBackingScaleItIsGiven() {
        let config = SSHLaunch.config(
            host: host, controlPath: URL(fileURLWithPath: "/tmp/1-ab"), form: .plain, backingScale: 2)

        XCTAssertEqual(config.backingScale, 2)
    }

    func test_thePathNamesThePidAndEightHexOfTheHost() {
        let path = SSHLaunch.controlPath(
            for: host, in: URL(fileURLWithPath: "/tmp/zt", isDirectory: true), fallback: fallback, pid: 42)

        XCTAssertEqual(path.deletingLastPathComponent().path, "/tmp/zt")
        XCTAssertTrue(path.lastPathComponent.hasPrefix("42-"))
        let hex = path.lastPathComponent.dropFirst("42-".count)
        XCTAssertEqual(hex.count, 8)
        XCTAssertTrue(hex.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(
            SSHLaunch.controlPath(
                for: SSHHostID(alias: "other"), in: URL(fileURLWithPath: "/tmp/zt"), fallback: fallback, pid: 42),
            path)
    }

    func test_aPathAtTheBudget_staysInItsFolder() {
        let dir = directory(makingPathBytes: 86)

        let path = SSHLaunch.controlPath(for: host, in: dir, fallback: fallback, pid: 12345)

        XCTAssertEqual(path.path.utf8.count, 86)
        XCTAssertEqual(path.deletingLastPathComponent().path, dir.path)
    }

    func test_aPathOverTheBudget_fallsBackToTheTempFolder() {
        let dir = directory(makingPathBytes: 87)

        let path = SSHLaunch.controlPath(for: host, in: dir, fallback: fallback, pid: 12345)

        XCTAssertEqual(path.deletingLastPathComponent().path, fallback.path)
        XCTAssertLessThanOrEqual(path.path.utf8.count, SSHLaunch.controlPathBudget)
    }

    func test_theCheckAsksTheMasterAtTheSamePath_withoutReadingTheUsersConfig() {
        XCTAssertEqual(
            SSHLaunch.checkArguments(host: host, controlPath: URL(fileURLWithPath: "/tmp/a b/1-ab")),
            [
                "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ControlPath=\"/tmp/a b/1-ab\"", "-O", "check", "--",
                "devbox",
            ])
    }

    func test_theMastersPidIsReadFromTheCheck() {
        XCTAssertEqual(SSHLaunch.masterPID(in: "Master running (pid=4242)\r"), 4242)
        XCTAssertNil(SSHLaunch.masterPID(in: "Control socket connect(/tmp/x): No such file or directory"))
        XCTAssertNil(SSHLaunch.masterPID(in: "pid=)"))
    }
}
