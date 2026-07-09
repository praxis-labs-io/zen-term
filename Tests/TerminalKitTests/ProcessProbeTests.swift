import Darwin
import XCTest

@testable import TerminalKit

/// The "busy" direction (a foreground command's group differs from the shell's) needs a real
/// pty + shell to exercise and is covered by the manual runbook (a pane running vim/sleep
/// reads busy; an idle prompt and a backgrounded job read idle). These cover the deterministic
/// guards plus the not-busy direction on a pty with no foreground group.
final class ProcessProbeTests: XCTestCase {
    func test_invalidFd_isNotBusy() {
        XCTAssertFalse(ProcessProbe.hasForegroundJob(masterFd: -1, shellPid: 1234))
    }

    func test_nonPositiveShellPid_isNotBusy() {
        XCTAssertFalse(ProcessProbe.hasForegroundJob(masterFd: 0, shellPid: 0))
        XCTAssertFalse(ProcessProbe.hasForegroundJob(masterFd: 3, shellPid: -1))
    }

    func test_freshPty_hasNoForegroundJob() {
        let master = posix_openpt(O_RDWR)
        guard master >= 0 else { return XCTFail("posix_openpt failed") }
        defer { close(master) }
        // No session or foreground command on a fresh pty → not busy, whatever pid we claim.
        XCTAssertFalse(ProcessProbe.hasForegroundJob(masterFd: master, shellPid: 99999))
    }
}
