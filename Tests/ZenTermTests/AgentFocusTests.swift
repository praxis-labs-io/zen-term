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
    private let originalDoneDecay = WindowController.doneDecay

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
        WindowController.doneDecay = 0.3
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        WindowController.doneDecay = originalDoneDecay
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

    private func wait(seconds: TimeInterval) {
        let elapsed = expectation(description: "elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 2)
    }

    private func finishATurn(on surface: RecordingSurface) {
        surface.delegate?.surface(surface, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()
        surface.delegate?.surface(surface, progressDidChange: nil)
        drainMainQueue()
    }

    func test_aTurnEndingInTheFocusedPane_readsIdleOnceYouHaveSeenIt() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        finishATurn(on: try XCTUnwrap(spawned.first))
        XCTAssertEqual(c.agentStateForTesting(pane), .completed, "precondition: the turn ended")

        wait(seconds: WindowController.doneDecay + 0.2)

        XCTAssertEqual(c.agentStateForTesting(pane), .idle)
        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "the tab number was never the list's to clear")
    }

    func test_aTurnEndingInAnUnfocusedSplit_staysDone() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let firstSurface = try XCTUnwrap(spawned.first)
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        finishATurn(on: firstSurface)

        wait(seconds: WindowController.doneDecay + 0.2)

        XCTAssertEqual(c.agentStateForTesting(first), .completed, "a pane you are not looking at keeps its news")
    }

    func test_focusingADonePane_startsTheClock() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        let firstSurface = try XCTUnwrap(spawned.first)
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        finishATurn(on: firstSurface)

        while c.focusedSurfaceIDForTesting != first { c.handle(.nextPane) }
        XCTAssertEqual(c.agentStateForTesting(first), .completed, "arriving is not reading it yet")
        wait(seconds: WindowController.doneDecay + 0.2)

        XCTAssertEqual(c.agentStateForTesting(first), .idle)
    }

    func test_leavingADonePaneAndComingBack_restartsTheClock() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        WindowController.doneDecay = 2
        finishATurn(on: try XCTUnwrap(spawned.first))
        wait(seconds: 1)

        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        while c.focusedSurfaceIDForTesting != first { c.handle(.nextPane) }
        wait(seconds: 1.5)

        XCTAssertEqual(
            c.agentStateForTesting(first), .completed, "coming back owes a whole interval, not what was left of one")
        wait(seconds: 1)
        XCTAssertEqual(c.agentStateForTesting(first), .idle)
    }

    func test_leavingTheSidebar_startsTheClock() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.handle(.focusSidebar)
        XCTAssertTrue(c.sidebarForTesting.hasFocus, "precondition: the keyboard is in the rows")
        finishATurn(on: try XCTUnwrap(spawned.first))

        c.sidebarForTesting.onLeave()
        wait(seconds: WindowController.doneDecay + 0.2)

        XCTAssertEqual(c.agentStateForTesting(pane), .idle)
    }

    func test_closingThePalette_startsTheClock() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.handle(.toggleCommandPalette)
        finishATurn(on: try XCTUnwrap(spawned.first))
        wait(seconds: WindowController.doneDecay + 0.2)
        XCTAssertEqual(c.agentStateForTesting(pane), .completed, "precondition: the palette covers the pane")

        c.handle(.toggleCommandPalette)
        wait(seconds: WindowController.doneDecay + 0.2)

        XCTAssertEqual(c.agentStateForTesting(pane), .idle)
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

    func test_leavingTheSidebarForAFloat_startsTheClock() throws {
        let c = makeWindow()
        let float = try openFloat(c)
        let row = try XCTUnwrap(c.sidebarForTesting.view.rowsForTesting.first)
        c.window.makeFirstResponder(row)
        XCTAssertTrue(c.sidebarForTesting.hasFocus, "precondition: a click put the keyboard in the rows")
        finishATurn(on: float.surface)

        c.sidebarForTesting.onLeave()
        wait(seconds: WindowController.doneDecay + 0.2)

        XCTAssertEqual(c.agentStateForTesting(float.id), .idle)
    }

    func test_anAgentThatExitedFailing_staysUntilItIsAnswered() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.identifyAgentForTesting(pane, name: "claude")
        c.notifyCommandFinishedForTesting(tabIndex: 0, result: TerminalCommandResult(exitCode: 1, duration: 1))
        drainMainQueue()
        XCTAssertEqual(c.agentStateForTesting(pane), .completed, "precondition: it exited failing")

        c.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        wait(seconds: WindowController.doneDecay + 0.2)

        XCTAssertEqual(c.agentStateForTesting(pane), .completed, "a failure waits for you to act on it")
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
            surface, didPostNotification: TerminalNotification(title: "pi", body: "Claude needs your permission"))
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
            surface, didPostNotification: TerminalNotification(title: "pi", body: "Claude needs your permission"))
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
            surface, didPostNotification: TerminalNotification(title: "pi", body: "Claude needs your permission"))
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
