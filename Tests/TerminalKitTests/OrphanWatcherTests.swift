import XCTest

@testable import TerminalKit

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

    private func waitForDeath(of pid: pid_t, timeout: TimeInterval = 8.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !isAlive(pid)
    }

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

    func test_watcherSweepsALeaderThatTakesItsTimeExiting() throws {
        let session = try startSession(childSleep: 953)
        XCTAssertTrue(isAlive(session.child), "child never started")

        ShellSessionLedger.shared.record([session.leader])

        ShellSessionReaper.shared.reapOrphans()

        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(
            isAlive(session.child), "child died before the leader did, so this proves nothing")
        kill(session.leader, SIGKILL)

        XCTAssertTrue(
            waitForDeath(of: session.child),
            "the leader exited after the sweep gave up, so the session was never swept")
    }

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

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(
            completed, "quit drain finished while a recorded session's leader was still alive")

        kill(session.leader, SIGKILL)
        wait(for: [drained], timeout: 10.0)
        XCTAssertFalse(
            isAlive(session.child), "quit drain finished before the session was swept")
    }

    // Stays green if `reapOrphans` enters the group inside its block; that race is too narrow to reproduce.
    func test_drainIssuedRightAfterReapOrphansWaitsForTheSweep() throws {
        let session = try startSession(childSleep: 956, childIgnoresTerm: true)
        XCTAssertTrue(isAlive(session.child), "child never started")
        ShellSessionLedger.shared.record([session.leader])

        kill(session.leader, SIGKILL)
        while isAlive(session.leader) { Thread.sleep(forTimeInterval: 0.01) }

        let start = Date()
        ShellSessionReaper.shared.reapOrphans()
        let drained = expectation(description: "drain finished")
        ShellSessionReaper.shared.drain(timeout: 5.0) { drained.fulfill() }
        wait(for: [drained], timeout: 8.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(
            elapsed, 0.1,
            "drain reported done in \(String(format: "%.3f", elapsed))s, before the graced sweep "
                + "could have run")
        XCTAssertTrue(waitForDeath(of: session.child), "the session was never swept")
    }

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

    func test_eachSessionIsSweptWhenItsOwnLeaderExits() throws {
        let first = try startSession(childSleep: 951)
        let second = try startSession(childSleep: 952)
        XCTAssertTrue(isAlive(first.child), "first child never started")
        XCTAssertTrue(isAlive(second.child), "second child never started")

        ShellSessionLedger.shared.record([first.leader, second.leader])

        kill(first.leader, SIGKILL)
        ShellSessionReaper.shared.reapOrphans()
        XCTAssertTrue(waitForDeath(of: first.child), "the first session was never swept")

        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(
            isAlive(second.child), "second child died on its own, so this proves nothing")
        kill(second.leader, SIGKILL)

        XCTAssertTrue(
            waitForDeath(of: second.child),
            "nothing was left watching the second leader, so its session ran on")
    }
}
