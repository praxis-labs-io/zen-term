import XCTest

@testable import TerminalKit

final class ShellSessionTests: XCTestCase {
    private var fixture: Process?
    private var scratch: URL?

    override func tearDown() {
        if let leader = leaderPID { ShellSession.members(of: leader).forEach { kill($0, SIGKILL) } }
        fixture?.terminate()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    private var leaderPID: pid_t?

    /// A session leader with a child parked in its own process group: the shape a SIGHUP to
    /// the leader's process group misses, and the whole reason this type exists.
    private func startSessionFixture() throws -> pid_t {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen269-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        let script = dir.appendingPathComponent("session.pl")
        let pidFile = dir.appendingPathComponent("leader.pid")
        try """
        POSIX::setsid() or die "setsid failed: $!";
        open(my $f, '>', $ARGV[0]) or die $!;
        print $f $$;
        close $f;
        if (fork() == 0) { setpgrp(0, 0); exec('/bin/sleep', '931'); }
        sleep 932;
        """.write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Backgrounded inside sh: sh is the process group leader, perl is not, so its
        // setsid() succeeds. Run perl directly and setsid fails with EPERM.
        p.arguments = ["-c", "/usr/bin/perl -MPOSIX '\(script.path)' '\(pidFile.path)' & wait"]
        try p.run()
        fixture = p

        var leader: pid_t?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, leader == nil {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                leader = pid
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let resolved = try XCTUnwrap(leader, "fixture never reported a leader pid")
        leaderPID = resolved
        return resolved
    }

    func test_membersFindsProcessesOutsideTheLeadersProcessGroup() throws {
        let leader = try startSessionFixture()
        // The forked child needs a moment to land in the process table.
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertEqual(getsid(leader), leader, "fixture is not a session leader")

        let members = ShellSession.members(of: leader)
        XCTAssertTrue(members.contains(leader), "members missed the session leader itself")
        XCTAssertGreaterThanOrEqual(
            members.count, 2, "members missed the child parked in its own process group")
        XCTAssertFalse(members.contains(getpid()), "members must never include us")
    }

    func test_leaderChildrenIgnoresOrdinaryHelperSubprocesses() throws {
        // A plain helper (the shape of a git probe) stays in our session, so it must not
        // read as a shell. This is the discriminator the pid capture in start() relies on.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["30"]
        try helper.run()
        defer { helper.terminate() }
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertNotEqual(
            getsid(helper.processIdentifier), helper.processIdentifier,
            "a Foundation helper unexpectedly leads a session")
        XCTAssertFalse(
            ShellSession.leaderChildren().contains(helper.processIdentifier),
            "leaderChildren claimed a plain helper subprocess")
    }
}
