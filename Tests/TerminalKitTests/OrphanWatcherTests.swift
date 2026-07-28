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

    /// Poll for the sweep to reach `pid` rather than sleeping a fixed interval and looking once.
    ///
    /// The timeout is a ceiling on failure, not a wait a green run pays: a sweep that lands in
    /// 50ms returns in 50ms. A fixed sleep here would be both a flake on a loaded machine and a
    /// tax on every passing run, which is what made the previous version of these tests
    /// timing-dependent (ZEN-306).
    private func waitForDeath(of pid: pid_t, timeout: TimeInterval = 8.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !isAlive(pid)
    }

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

    /// A leader that takes longer to exit than the watcher is willing to wait.
    ///
    /// This is the shape of a pane running a dev server: freeing the surface closes the pty, but
    /// the shell is waiting on a foreground child that takes its time shutting down, so the
    /// session leader is still alive when the watcher gives up. Nothing reschedules a look, so on
    /// the last pane the session sits in the ledger forever and its children outlive the close.
    func test_watcherSweepsALeaderThatTakesItsTimeExiting() throws {
        let session = try startSession(childSleep: 953)
        XCTAssertTrue(isAlive(session.child), "child never started")

        ShellSessionLedger.shared.record([session.leader])

        // The surface is freed and the sweep runs, but the leader is still running, so there is
        // nothing orphaned to find yet.
        ShellSessionReaper.shared.reapOrphans()

        // Well past the 1.0s window the sweep used to give up at. Any fixed budget is a guess:
        // a shell waiting on a foreground child exits when that child does, not on a schedule.
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(
            isAlive(session.child), "child died before the leader did, so this proves nothing")
        kill(session.leader, SIGKILL)

        XCTAssertTrue(
            waitForDeath(of: session.child),
            "the leader exited after the sweep gave up, so the session was never swept")
    }

    /// A second session orphaning long after the first has already been swept, with no second
    /// `reapOrphans()` call to rescue it.
    ///
    /// That is the shape of two panes closing a moment apart, and of one pane closing while
    /// another's shell is still winding down. Each leader is watched for its own exit, so the
    /// gap between them does not matter and nothing has to still be looking when the second
    /// one goes.
    func test_eachSessionIsSweptWhenItsOwnLeaderExits() throws {
        let first = try startSession(childSleep: 951)
        let second = try startSession(childSleep: 952)
        XCTAssertTrue(isAlive(first.child), "first child never started")
        XCTAssertTrue(isAlive(second.child), "second child never started")

        ShellSessionLedger.shared.record([first.leader, second.leader])

        // The first pane closes and its shell exits.
        kill(first.leader, SIGKILL)
        ShellSessionReaper.shared.reapOrphans()
        XCTAssertTrue(waitForDeath(of: first.child), "the first session was never swept")

        // The second closed at the same time but its shell takes far longer to go, well past
        // any window the sweep used to run on. Deliberately no second `reapOrphans()` here.
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(
            isAlive(second.child), "second child died on its own, so this proves nothing")
        kill(second.leader, SIGKILL)

        XCTAssertTrue(
            waitForDeath(of: second.child),
            "nothing was left watching the second leader, so its session ran on")
    }
}
