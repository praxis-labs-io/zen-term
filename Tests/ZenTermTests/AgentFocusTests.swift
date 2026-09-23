import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class AgentFocusTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        var config = GeneralConfig.builtIn
        config.attentionToast = .sticky
        GeneralConfig.setCurrentForTesting(config)
        WindowController.isPresent = { _ in true }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        c.mountAndStart()
        controller = c
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    func test_anAgentWaitingInAnUnfocusedSplit_staysWaitingUntilItIsAnswered() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let firstSurface = try XCTUnwrap(spawned.first)
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(c.focusedSurfaceIDForTesting, first, "precondition: the split takes focus")

        firstSurface.delegate?.surface(
            firstSurface, didPostNotification: TerminalNotification(title: "", body: "Wants to run swift test"))
        drainMainQueue()

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "the tab number keeps using tab activeness")
        XCTAssertEqual(c.agentStateForTesting(first), .waiting)

        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(c.agentStateForTesting(first), .waiting, "focusing another pane does not answer it")

        while c.focusedSurfaceIDForTesting != first { c.handle(.nextPane) }
        XCTAssertEqual(c.agentStateForTesting(first), .waiting, "focusing it back is not answering it either")

        c.answerTypedAgent()

        XCTAssertEqual(c.agentStateForTesting(first), .idle)
    }

    func test_aTurnEndingInAnUnfocusedSplit_readsDone() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let firstSurface = try XCTUnwrap(spawned.first)
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()

        firstSurface.delegate?.surface(
            firstSurface, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()
        XCTAssertEqual(c.agentStateForTesting(first), .working)

        firstSurface.delegate?.surface(firstSurface, progressDidChange: nil)
        drainMainQueue()

        XCTAssertEqual(c.agentStateForTesting(first), .completed)
        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0))
    }

    func test_anAgentThatAsksWhileYouAreAway_waitsEvenInTheFocusedPane() throws {
        WindowController.isPresent = { _ in false }
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let surface = try XCTUnwrap(spawned.first)

        surface.delegate?.surface(surface, didPostNotification: TerminalNotification(title: "", body: "Done?"))
        drainMainQueue()
        XCTAssertEqual(c.agentStateForTesting(pane), .waiting)

        WindowController.isPresent = { _ in true }
        c.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertEqual(
            c.agentStateForTesting(pane), .waiting,
            "coming back to the window is looking at the prompt, not answering it")

        c.answerTypedAgent()

        XCTAssertEqual(c.agentStateForTesting(pane), .idle)
    }

    func test_aTurnEndingOnAWaitingAgent_takesTheWordsWithTheTone() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let surface = try XCTUnwrap(spawned.first)
        c.notifyProgressForTesting(tabIndex: 0, progress: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()

        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "", body: "Claude needs your permission"))
        drainMainQueue()
        XCTAssertEqual(c.agentStateForTesting(pane), .waiting)

        c.notifyProgressForTesting(tabIndex: 0, progress: nil)
        drainMainQueue()

        XCTAssertEqual(c.agentStateForTesting(pane), .completed, "a latch cannot outlive its turn")
        let row = try XCTUnwrap(c.agentRowForTesting(pane))
        XCTAssertEqual(
            row.summary, row.state.summary,
            "a turn ending clears the words with the tone, or the row reads blocked under a done dot")
    }

    func test_typingIntoTheFindField_doesNotAnswerTheAgent() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let surface = try XCTUnwrap(spawned.first)

        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "", body: "Claude needs your permission"))
        drainMainQueue()
        XCTAssertEqual(c.agentStateForTesting(pane), .waiting)

        c.handle(.toggleSearch)
        XCTAssertTrue(c.search.isEditing, "precondition: the find field holds the keys")
        c.answerTypedAgent()

        XCTAssertEqual(
            c.agentStateForTesting(pane), .waiting, "the keys went to the find field, not to the agent")
    }

    func test_typingIntoAWatchedPane_answersIt_andTheRowStopsSayingBlocked() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let surface = try XCTUnwrap(spawned.first)

        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "", body: "Claude needs your permission"))
        drainMainQueue()
        let asking = try XCTUnwrap(c.agentRowForTesting(pane))
        XCTAssertEqual(c.agentStateForTesting(pane), .waiting, "a prompt you watched arrive is still blocked")
        XCTAssertEqual(asking.summary, "Claude needs your permission")

        c.answerTypedAgent()
        drainMainQueue()

        XCTAssertEqual(c.agentStateForTesting(pane), .idle)
        let answered = try XCTUnwrap(c.agentRowForTesting(pane))
        XCTAssertEqual(
            answered.summary, answered.state.summary,
            "the row's words have to agree with its tone, or it reads blocked while it looks idle")
    }
}
