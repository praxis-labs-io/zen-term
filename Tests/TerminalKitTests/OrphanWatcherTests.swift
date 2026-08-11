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
    /// timing-dependent.
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
    ///
    /// `childIgnoresTerm` makes the child survive the sweep's `SIGTERM` so that only the
    /// `SIGKILL` pass, one `grace` later, can end it. That widens the sweep from microseconds to
    /// 150ms, which is what makes "did the drain wait for the sweep" observable at all: a child
    /// that dies on `SIGTERM` is already gone by the time any assertion looks, so the test passes
    /// whether the drain waited or not.
    private func startSession(childSleep: Int, childIgnoresTerm: Bool = false) throws -> Session {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen269-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.append(dir)
        let script = dir.appendingPathComponent("session.pl")
        let pidFile = dir.appendingPathComponent("pids")
        let childBody =
            childIgnoresTerm
            ? "$0 = 'zen306-stubborn-\(childSleep)'; $SIG{TERM} = 'IGNORE'; sleep \(childSleep); exit 0;"
            : "exec('/bin/sleep', '\(childSleep)');"
        try """
        POSIX::setsid() or die "setsid failed: $!";
        my $kid = fork();
        if ($kid == 0) { setpgrp(0, 0); \(childBody) }
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

    /// The quit drain must not report done while a recorded session's leader is still running,
    /// and must not report done until that session has actually been swept.
    ///
    /// This is the path `AppDelegate` takes on ⌘Q, and nothing covered it: `QuitTeardownTests`
    /// drives quit through fakes that never touch the ledger, so `drainAllSessions` ran on an
    /// empty ledger and degenerated to the old group drain. Both halves below ship green with the
    /// wait condition inverted or with the sweep's reserve removed, which is how this got as
    /// far as review with the quit path broken.
    func test_quitDrainWaitsForTheLedgerAndThenForTheSweep() throws {
        let session = try startSession(childSleep: 954)
        XCTAssertTrue(isAlive(session.child), "child never started")
        ShellSessionLedger.shared.record([session.leader])

        var completed = false
        let drained = expectation(description: "quit drain finished")
        ShellSessionReaper.shared.drainForQuit(timeout: 5.0) {
            completed = true
            drained.fulfill()
        }

        // Pump rather than sleep: the completion lands on main, so blocking main would make the
        // assertion below vacuously true.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(
            completed, "quit drain finished while a recorded session's leader was still alive")

        kill(session.leader, SIGKILL)
        wait(for: [drained], timeout: 10.0)
        XCTAssertFalse(
            isAlive(session.child), "quit drain finished before the session was swept")
    }

    /// A `drain` issued on the statement after `reapOrphans` must not report done before the
    /// sweep has run.
    ///
    /// This is `SurfaceTeardownLeakTests.teardownAndDrain`'s exact shape (`terminate()` then
    /// `drain` on the next line) with fixtures instead of real surfaces, so it is fast and does
    /// not depend on a real shell.
    ///
    /// **What it guards:** that the graced pass is inside the pending group at all. Removing
    /// `reap`'s `pending.enter()` makes the drain return in about 9ms and this test fails.
    ///
    /// **What it does not guard**, checked by mutation rather than assumed: moving
    /// `reapOrphans`' own `pending.enter()` back inside the dispatched block leaves this test
    /// green. That race is real (the group is briefly empty between the dispatch and the block
    /// running, so a drain landing in the gap reports done before anything has begun) but the
    /// window is a few instructions wide and does not reproduce on demand. The enter stays on
    /// the caller's thread because it is correct by construction and free, not because anything
    /// here would catch its absence.
    func test_drainIssuedRightAfterReapOrphansWaitsForTheSweep() throws {
        // Ignores SIGTERM, so only the SIGKILL pass one `grace` later ends it. Without that the
        // child dies instantly and the test cannot see whether the drain waited.
        let session = try startSession(childSleep: 956, childIgnoresTerm: true)
        XCTAssertTrue(isAlive(session.child), "child never started")
        ShellSessionLedger.shared.record([session.leader])

        // Orphan it first, so there is real work for the sweep to find and the only question is
        // whether the drain waits for it.
        kill(session.leader, SIGKILL)
        while isAlive(session.leader) { Thread.sleep(forTimeInterval: 0.01) }

        let start = Date()
        ShellSessionReaper.shared.reapOrphans()
        let drained = expectation(description: "drain finished")
        ShellSessionReaper.shared.drain(timeout: 5.0) { drained.fulfill() }
        wait(for: [drained], timeout: 8.0)
        let elapsed = Date().timeIntervalSince(start)

        // Elapsed time is the signal, not liveness: `kill(pid, 0)` succeeds on a zombie, so
        // looking at the child the instant the drain returns races the kernel reaping it. A drain
        // that waited for the sweep cannot come back before the SIGTERM, the grace and the
        // SIGKILL have all happened; one that reported an empty group comes back in about no time.
        XCTAssertGreaterThan(
            elapsed, 0.1,
            "drain reported done in \(String(format: "%.3f", elapsed))s, before the graced sweep "
                + "could have run")
        XCTAssertTrue(waitForDeath(of: session.child), "the session was never swept")
    }

    /// A shell that never notices its pty must still be swept on quit, not merely waited on.
    ///
    /// The leader here stays alive for the whole drain, which is what a foreground child that
    /// traps or ignores `SIGHUP` looks like (ssh, a build, a dev server with its own handler).
    /// Waiting cannot help, because only a leader exiting empties the ledger: without the
    /// outright sweep, quit pays its full budget as a hang and *then* leaves the session running,
    /// which is both halves of the bargain lost.
    ///
    /// Safe only because quit tears every surface down first, so nothing left in the ledger can
    /// belong to a live pane. `test_eachSessionIsSweptWhenItsOwnLeaderExits` covers the other
    /// side: a sibling that is still alive is never in reach.
    func test_quitSweepsAStragglerWhoseLeaderNeverExits() throws {
        let session = try startSession(childSleep: 955)
        XCTAssertTrue(isAlive(session.child), "child never started")
        ShellSessionLedger.shared.record([session.leader])

        let drained = expectation(description: "quit drain finished")
        let start = Date()
        ShellSessionReaper.shared.drainForQuit(timeout: 1.0) { drained.fulfill() }
        wait(for: [drained], timeout: 10.0)

        XCTAssertLessThan(
            Date().timeIntervalSince(start), 5.0, "quit drain ran far past its budget")
        XCTAssertTrue(
            waitForDeath(of: session.child),
            "the leader never exited, so quit waited and then left the session running")
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
