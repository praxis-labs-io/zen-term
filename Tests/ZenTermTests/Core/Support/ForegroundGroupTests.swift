import XCTest

@testable import ZenTerm

final class ForegroundGroupTests: XCTestCase {
    private func processes(session: pid_t, parent: pid_t, leader: String) -> ForegroundGroup.Processes {
        ForegroundGroup.Processes(
            session: { _ in session }, parent: { _ in parent }, command: { $0 == session ? leader : nil })
    }

    func test_aGroupThatLeadsItsSessionIsTheShell() {
        XCTAssertTrue(ForegroundGroup.isShell(40, in: processes(session: 40, parent: 1, leader: "zsh")))
    }

    func test_theChildOfALoginThatLeadsTheSessionIsTheShell() {
        XCTAssertTrue(ForegroundGroup.isShell(41, in: processes(session: 40, parent: 40, leader: "login")))
    }

    func test_aJobOfAShellThatLeadsItsSessionIsNotTheShell() {
        XCTAssertFalse(ForegroundGroup.isShell(41, in: processes(session: 40, parent: 40, leader: "zsh")))
    }

    func test_aGrandchildOfTheLeaderIsNotTheShell() {
        XCTAssertFalse(ForegroundGroup.isShell(42, in: processes(session: 40, parent: 41, leader: "login")))
    }

    func test_aGroupWithNoSessionIsNotTheShell() {
        XCTAssertFalse(ForegroundGroup.isShell(42, in: processes(session: -1, parent: 41, leader: "login")))
    }

    func test_theSystemReadsAProcesssParentAndCommand() throws {
        XCTAssertEqual(ForegroundGroup.system.parent(getpid()), getppid())
        let command = try XCTUnwrap(ForegroundGroup.system.command(getpid()))
        XCTAssertFalse(command.isEmpty)
        XCTAssertTrue(ProcessInfo.processInfo.processName.hasPrefix(command), command)
    }
}
