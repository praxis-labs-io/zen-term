import ControlProtocol
import XCTest

@testable import zen

final class WaitAnswerTests: XCTestCase {
    private let pane = ListResult.Pane(
        token: 34, drawer: nil, title: "", cwd: nil, busy: false, agent: nil, name: nil, parent: nil, firstTask: nil)

    private func code(_ reason: WaitReason, exitCode: Int? = nil) -> Int32 {
        WaitAnswer.exitCode(for: WaitResult(reason: reason, exitCode: exitCode, pane: pane))
    }

    private func code(_ reason: WaitReason, children: [(WaitReason?, Int?)]) -> Int32 {
        WaitAnswer.exitCode(
            for: WaitResult(
                reason: reason,
                children: children.map { WaitResult.Child(reason: $0.0, exitCode: $0.1, pane: pane) }))
    }

    func test_aWaitOnAPaneExits0OnlyForACleanExitTheTextOrAStop() {
        XCTAssertEqual(code(.exited, exitCode: 0), 0)
        XCTAssertEqual(code(.output), 0)
        XCTAssertEqual(code(.stopped), 0)
        XCTAssertEqual(code(.exited, exitCode: 1), 4)
        XCTAssertEqual(code(.exited), 4, "an exit with no known code is not a clean one")
        XCTAssertEqual(code(.timeout), 5)
        XCTAssertEqual(code(.message), 6)
    }

    func test_aWaitOnChildrenExits4WhenAnyChildsProgramFailed() {
        XCTAssertEqual(code(.stopped, children: [(.stopped, nil), (nil, nil)]), 0)
        XCTAssertEqual(code(.stopped, children: [(.exited, 0), (.stopped, nil)]), 0)
        XCTAssertEqual(code(.stopped, children: [(.exited, 2), (.stopped, nil)]), 4)
        XCTAssertEqual(code(.exited, children: [(.exited, nil)]), 4)
        XCTAssertEqual(code(.exited, children: [(.exited, 0)]), 0)
        XCTAssertEqual(code(.timeout, children: [(.exited, 1)]), 5)
        XCTAssertEqual(code(.message, children: [(nil, nil)]), 6)
        XCTAssertEqual(code(.noChildren, children: []), 0)
    }
}
