import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// OSC 9;4 is the one signal that says an agent is mid-turn. It must not reach the tab bar.
final class AgentWorkingStateTests: WindowTestCase {
    private var controller: WindowController?

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        return controller
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    func test_anIndeterminateReport_readsWorking() {
        let controller = makeController()
        controller.newTabForTesting()

        controller.notifyProgressForTesting(tabIndex: 0, progress: TerminalProgress(state: .indeterminate))
        drainMainQueue()

        XCTAssertEqual(controller.surfaceAttentionForTesting(tabIndex: 0), .working)
    }

    func test_working_colorsNoTabNumber() {
        let controller = makeController()
        controller.newTabForTesting()

        controller.notifyProgressForTesting(tabIndex: 0, progress: TerminalProgress(state: .indeterminate))
        drainMainQueue()

        XCTAssertNil(
            controller.attentionStateForTesting(tabIndex: 0),
            "a working agent is not asking for you, so its tab stays uncolored")
    }

    func test_progressClearing_lowersWorkingAgain() {
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyProgressForTesting(tabIndex: 0, progress: TerminalProgress(state: .indeterminate))
        drainMainQueue()

        controller.notifyProgressForTesting(tabIndex: 0, progress: nil)
        drainMainQueue()

        XCTAssertEqual(controller.surfaceAttentionForTesting(tabIndex: 0), .idle)
    }

    func test_aDeterminateReport_isAProgressBar_notAnAgentTurn() {
        let controller = makeController()
        controller.newTabForTesting()

        controller.notifyProgressForTesting(
            tabIndex: 0, progress: TerminalProgress(state: .running, fraction: 0.4))
        drainMainQueue()

        XCTAssertEqual(controller.surfaceAttentionForTesting(tabIndex: 0), .idle)
    }

    func test_working_neverMasksAnAgentWaiting() {
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()

        controller.notifyProgressForTesting(tabIndex: 0, progress: TerminalProgress(state: .indeterminate))
        drainMainQueue()

        XCTAssertEqual(controller.attentionStateForTesting(tabIndex: 0), .waiting)
    }

    func test_progressClearing_neverClearsAnAgentWaiting() {
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()

        controller.notifyProgressForTesting(tabIndex: 0, progress: nil)
        drainMainQueue()

        XCTAssertEqual(controller.attentionStateForTesting(tabIndex: 0), .waiting)
    }
}
