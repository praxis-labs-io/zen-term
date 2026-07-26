import XCTest

@testable import TerminalKit

/// The orphan watcher, driven against synthetic sessions so leader death is scheduled rather
/// than raced. `SurfaceTeardownLeakTests` covers the same ground end to end but cannot reach
/// this case: there, both leaders exit within about 45ms of each other, so the window this
/// guards only opens on timing variance.
final class OrphanWatcherTests: XCTestCase {
    private struct Session {
        let leader: pid_t
        let child: pid_t
    }

    private var fixtures: [Process] = []
    private var scratch: [URL] = []
    private var started: [Session] = []

    override func tearDown() {
        for session in started {
            kill(session.child, SIGKILL)
            kill(session.leader, SIGKILL)
        }
        fixtures.forEach { $0.terminate() }
        scratch.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// A session leader with one child parked in its own process group, so killing the leader
    /// orphans the session while leaving the child running. `childSleep` distinguishes the
    /// children of two concurrent fixtures.
    private func startSession(childSleep: Int) throws -> Session {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen269-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.append(dir)
        let script = dir.appendingPathComponent("session.pl")
        let pidFile = dir.appendingPathComponent("pids")
        try """
        POSIX::setsid() or die "setsid failed: $!";
        my $kid = fork();
        if ($kid == 0) { setpgrp(0, 0); exec('/bin/sleep', '\(childSleep)'); }
        open(my $f, '>', $ARGV[0]) or die $!;
        print $f "$$ $kid";
        close $f;
        sleep 999;
        """.write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Backgrounded inside sh so perl is not the process group leader: setsid() fails with
        // EPERM if it is, and the fixture would silently never lead a session.
        p.arguments = ["-c", "/usr/bin/perl -MPOSIX '\(script.path)' '\(pidFile.path)' & wait"]
        try p.run()
        fixtures.append(p)

        var parsed: Session?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, parsed == nil {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                let parts = text.split(separator: " ").compactMap { pid_t($0) }
                if parts.count == 2 { parsed = Session(leader: parts[0], child: parts[1]) }
            }
            if parsed == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        let session = try XCTUnwrap(parsed, "fixture never reported its pids")
        started.append(session)
        XCTAssertEqual(getsid(session.leader), session.leader, "fixture does not lead a session")
        return session
    }

    /// A second session orphaning *after* the watcher has already swept the first, with no
    /// second `reapOrphans()` call to rescue it.
    ///
    /// That is exactly the shape of two panes closing a moment apart: the second teardown's
    /// call is coalesced into the running watcher, so if that watcher stops at its first find,
    /// nothing is left looking when the second leader finally exits. Its pane's dev server then
    /// outlives the close, which is the bug this whole ticket is about.
    func test_watcherSweepsASessionThatOrphansAfterTheFirstSweep() throws {
        let first = try startSession(childSleep: 951)
        let second = try startSession(childSleep: 952)
        Thread.sleep(forTimeInterval: 0.3)  // let both children land in the process table
        XCTAssertTrue(isAlive(first.child), "first child never started")
        XCTAssertTrue(isAlive(second.child), "second child never started")

        ShellSessionLedger.shared.record([first.leader, second.leader])

        // Orphan the first, then start watching: this is the first pane closing.
        kill(first.leader, SIGKILL)
        ShellSessionReaper.shared.reapOrphans()

        // Long enough for the watcher to find and sweep the first. A watcher that stops there
        // has already exited by the time the second orphans below.
        Thread.sleep(forTimeInterval: 0.3)

        // The second pane closed while the watcher was running, so its own `reapOrphans()` was
        // coalesced away. Deliberately not called again here — that is the bug's precondition.
        kill(second.leader, SIGKILL)

        let swept = expectation(description: "sweep finished")
        ShellSessionReaper.shared.drain(timeout: 5.0) { swept.fulfill() }
        wait(for: [swept], timeout: 8.0)

        XCTAssertFalse(isAlive(first.child), "the first session was never swept")
        XCTAssertFalse(
            isAlive(second.child),
            "the watcher stopped at its first sweep and left the second session running")
    }
}
