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
        config.ai = "pi"
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

    private func finishATurn(on surface: RecordingSurface) {
        surface.delegate?.surface(surface, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()
        surface.delegate?.surface(surface, progressDidChange: nil)
        drainMainQueue()
    }

    private func texts(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(texts)
    }

    func test_aTurnEndingInTheFocusedPane_readsIdle_andLatchesNothing() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.identifyAgentForTesting(pane, name: "claude")

        finishATurn(on: try XCTUnwrap(spawned.first))

        XCTAssertEqual(c.agentStateForTesting(pane), .idle, "a turn you watched end is not waiting on you")
        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0))
        XCTAssertNil(c.waitingToastForTesting(tabIndex: 0))
    }

    func test_aTurnEndingInAVisibleSplit_latchesNothing() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.identifyAgentForTesting(first, name: "claude")
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(c.focusedSurfaceIDForTesting, first, "precondition: the split takes focus")

        finishATurn(on: try XCTUnwrap(spawned.first))

        XCTAssertEqual(c.agentStateForTesting(first), .idle, "a pane on screen is in view, focused or not")
        XCTAssertNil(c.waitingToastForTesting(tabIndex: 0))
    }

    func test_aTurnEndingWhileYouAreAway_waitsWithItsOwnWords() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.identifyAgentForTesting(pane, name: "claude")
        WindowController.isPresent = { _ in false }

        finishATurn(on: try XCTUnwrap(spawned.first))

        XCTAssertEqual(c.agentStateForTesting(pane), .waiting)
        XCTAssertEqual(c.agentWaitForTesting(pane), .turnEnd)
        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .waiting)
        XCTAssertEqual(c.agentRowForTesting(pane)?.summary, "Finished its turn.")
        let card = try XCTUnwrap(c.waitingToastForTesting(tabIndex: 0))
        XCTAssertTrue(texts(in: card).contains("Finished its turn."))
    }

    func test_comingBackToAFinishedTurn_answersIt() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.identifyAgentForTesting(pane, name: "claude")
        WindowController.isPresent = { _ in false }
        finishATurn(on: try XCTUnwrap(spawned.first))
        XCTAssertEqual(c.agentStateForTesting(pane), .waiting, "precondition: it finished while you were away")

        WindowController.isPresent = { _ in true }
        c.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertEqual(c.agentStateForTesting(pane), .idle, "looking at a finished turn is all it asked of you")
        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0))
        XCTAssertEqual(c.agentRowForTesting(pane)?.summary, AttentionTone.idle.summary)
    }

    func test_aNewTurn_answersAFinishedTurn_andTakesDownItsCard() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let surface = try XCTUnwrap(spawned.first)
        c.identifyAgentForTesting(pane, name: "claude")
        WindowController.isPresent = { _ in false }
        finishATurn(on: surface)
        XCTAssertNotNil(c.waitingToastForTesting(tabIndex: 0), "precondition: the finished turn raised its card")

        surface.delegate?.surface(surface, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()

        XCTAssertEqual(c.agentStateForTesting(pane), .working)
        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0))
        XCTAssertNil(c.waitingToastForTesting(tabIndex: 0), "a card for a turn that moved on is stale")
    }

    func test_anUnnamedAgentsTurnEnd_latchesNothing_evenWhileYouAreAway() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        WindowController.isPresent = { _ in false }

        finishATurn(on: try XCTUnwrap(spawned.first))

        XCTAssertEqual(c.agentStateForTesting(pane), .idle, "a program that only reported progress has no turns")
        XCTAssertNil(c.waitingToastForTesting(tabIndex: 0))
    }

    private func openFloat(_ c: WindowController) throws -> (surface: RecordingSurface, id: SurfaceID) {
        var config = GeneralConfig.current
        config.floats = [
            ToolFloat(
                id: "agent", order: 0, title: "agent", icon: ToolFloatParser.defaultIcon, command: "agent",
                dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: .window,
                toggle: Chord(command: true, shift: true, key: "b"))
        ]
        GeneralConfig.setCurrentForTesting(config)
        c.handle(.toggleToolFloat("agent"))
        drainMainQueue()
        let surface = try XCTUnwrap(spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "agent"] })
        let id = try XCTUnwrap(c.floatsForTesting.surfaceID("agent"))
        XCTAssertEqual(c.floatsForTesting.activeID, "agent", "precondition: the float is shown")
        return (surface, id)
    }

    func test_aTurnEndingInAHiddenFloat_waits() throws {
        let c = makeWindow()
        let float = try openFloat(c)
        c.identifyAgentForTesting(float.id, name: "claude")
        c.handle(.toggleToolFloat("agent"))
        XCTAssertNil(c.floatsForTesting.activeID, "precondition: the float is hidden")

        finishATurn(on: float.surface)

        XCTAssertEqual(c.agentWaitForTesting(float.id), .turnEnd)
    }

    func test_anAgentThatExitedFailing_staysUntilItIsAnswered() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.identifyAgentForTesting(pane, name: "claude")
        c.notifyCommandFinishedForTesting(tabIndex: 0, result: TerminalCommandResult(exitCode: 1, duration: 1))
        drainMainQueue()
        XCTAssertEqual(c.agentStateForTesting(pane), .waiting, "precondition: it exited failing")

        c.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertEqual(c.agentStateForTesting(pane), .waiting, "a crash waits for you to act on it")
        XCTAssertEqual(c.agentRowForTesting(pane)?.summary, "Exited 1 after 1s.")
    }

    func test_anAgentWaitingInAnUnfocusedSplit_staysWaitingUntilItIsAnswered() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let firstSurface = try XCTUnwrap(spawned.first)
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(c.focusedSurfaceIDForTesting, first, "precondition: the split takes focus")

        firstSurface.delegate?.surface(
            firstSurface, didPostNotification: TerminalNotification(title: "pi", body: "Wants to run swift test"))
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

    func test_anAgentThatAsksWhileYouAreAway_waitsEvenInTheFocusedPane() throws {
        WindowController.isPresent = { _ in false }
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let surface = try XCTUnwrap(spawned.first)

        surface.delegate?.surface(surface, didPostNotification: TerminalNotification(title: "pi", body: "Done?"))
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
            surface,
            didPostNotification: TerminalNotification(
                title: AgentNotificationFixtures.claudeTitle, body: AgentNotificationFixtures.claudePermission))
        drainMainQueue()
        XCTAssertEqual(c.agentStateForTesting(pane), .waiting)

        c.notifyProgressForTesting(tabIndex: 0, progress: nil)
        drainMainQueue()

        XCTAssertEqual(c.agentStateForTesting(pane), .idle, "an ask cannot outlive its turn")
        let row = try XCTUnwrap(c.agentRowForTesting(pane))
        XCTAssertEqual(
            row.summary, row.state.summary,
            "a turn ending clears the words with the tone, or the row reads blocked under an idle dot")
    }

    func test_typingIntoTheFindField_doesNotAnswerTheAgent() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let surface = try XCTUnwrap(spawned.first)

        surface.delegate?.surface(
            surface,
            didPostNotification: TerminalNotification(
                title: AgentNotificationFixtures.claudeTitle, body: AgentNotificationFixtures.claudePermission))
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
        c.identifyAgentForTesting(pane, name: "pi")

        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "pi", body: "Approve the plan?"))
        drainMainQueue()
        let asking = try XCTUnwrap(c.agentRowForTesting(pane))
        XCTAssertEqual(c.agentStateForTesting(pane), .waiting, "a prompt you watched arrive is still blocked")
        XCTAssertEqual(asking.summary, "Approve the plan?")

        c.answerTypedAgent()
        drainMainQueue()

        XCTAssertEqual(c.agentStateForTesting(pane), .idle)
        let answered = try XCTUnwrap(c.agentRowForTesting(pane))
        XCTAssertEqual(
            answered.summary, answered.state.summary,
            "the row's words have to agree with its tone, or it reads blocked while it looks idle")
    }
}
