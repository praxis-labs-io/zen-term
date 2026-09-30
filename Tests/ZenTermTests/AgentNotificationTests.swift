import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class AgentNotificationTests: WindowTestCase {
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
        config.completionToast = .sticky
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

    private func backgroundPane(_ c: WindowController) throws -> (surface: RecordingSurface, id: SurfaceID) {
        let surface = try XCTUnwrap(spawned.last)
        let id = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.newTabForTesting()
        drainMainQueue()
        return (surface, id)
    }

    private func post(_ surface: RecordingSurface, title: String, body: String) {
        surface.delegate?.surface(surface, didPostNotification: TerminalNotification(title: title, body: body))
        drainMainQueue()
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func cardCopy(_ c: WindowController) -> [String] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
            .flatMap { descendants(of: $0) }
            .compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    func test_aShellsNotification_readsFinished_andJoinsNoList() throws {
        let c = makeWindow()
        let shell = try backgroundPane(c)

        post(shell.surface, title: "", body: "Build finished")

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .completed, "news, not a question")
        XCTAssertNil(c.agentRowForTesting(shell.id), "a shell is not an agent")
        XCTAssertTrue(cardCopy(c).contains("Build finished"), "the card says what the shell said")
    }

    func test_aShellsNotification_inAPaneYouAreLookingAt_raisesNothing() throws {
        let c = makeWindow()
        let surface = try XCTUnwrap(spawned.last)

        post(surface, title: "", body: "Build finished")

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0))
        XCTAssertTrue(cardCopy(c).isEmpty)
    }

    func test_aShellsNotification_neverTakesTheCardOfATabStillAsking() throws {
        let c = makeWindow()
        let claude = try XCTUnwrap(spawned.last)
        c.handle(.splitHorizontal)
        let shell = try XCTUnwrap(spawned.last)
        c.newTabForTesting()
        drainMainQueue()
        post(
            claude, title: AgentNotificationFixtures.claudeTitle, body: AgentNotificationFixtures.claudePermission)

        post(shell, title: "", body: "Build finished")

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .waiting)
        XCTAssertTrue(cardCopy(c).contains(AgentNotificationFixtures.claudePermission))
        XCTAssertFalse(cardCopy(c).contains("Build finished"))
    }

    func test_claudeAskingForPermission_waits() throws {
        let c = makeWindow()
        let claude = try backgroundPane(c)

        post(
            claude.surface, title: AgentNotificationFixtures.claudeTitle,
            body: AgentNotificationFixtures.claudePermission)

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .waiting)
        XCTAssertEqual(c.agentRowForTesting(claude.id)?.state, .waiting)
    }

    private func finishATurn(on surface: RecordingSurface) {
        surface.delegate?.surface(surface, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        drainMainQueue()
        surface.delegate?.surface(surface, progressDidChange: nil)
        drainMainQueue()
    }

    func test_claudesIdlePrompt_fromAClaudeReportingNoProgress_waits() throws {
        let c = makeWindow()
        let claude = try backgroundPane(c)

        post(
            claude.surface, title: AgentNotificationFixtures.claudeTitle,
            body: AgentNotificationFixtures.claudeIdlePrompt)

        XCTAssertEqual(
            c.attentionStateForTesting(tabIndex: 0), .waiting, "with its progress off, this is the only turn end")
        XCTAssertEqual(c.agentRowForTesting(claude.id)?.state, .waiting)
        XCTAssertEqual(cardCount(c), 1)
    }

    func test_claudesIdlePrompt_afterATurnYouSaw_changesNothing() throws {
        let c = makeWindow()
        let surface = try XCTUnwrap(spawned.last)
        let id = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.identifyAgentForTesting(id, name: "claude")
        finishATurn(on: surface)
        c.newTabForTesting()
        drainMainQueue()

        post(surface, title: AgentNotificationFixtures.claudeTitle, body: AgentNotificationFixtures.claudeIdlePrompt)

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "you saw the turn end, so nothing new is waiting")
        XCTAssertEqual(c.agentRowForTesting(id)?.state, .idle)
        XCTAssertNil(c.agentMessageForTesting(id), "an idle row never says Claude is waiting for your input")
        XCTAssertEqual(cardCount(c), 0)
    }

    func test_claudesIdlePrompt_afterATurnYouMissed_raisesNoSecondCard() throws {
        let c = makeWindow()
        let claude = try backgroundPane(c)
        c.identifyAgentForTesting(claude.id, name: "claude")
        finishATurn(on: claude.surface)
        XCTAssertEqual(cardCount(c), 1, "precondition: the turn end raised its card")

        post(
            claude.surface, title: AgentNotificationFixtures.claudeTitle,
            body: AgentNotificationFixtures.claudeIdlePrompt)

        XCTAssertEqual(cardCount(c), 1)
        XCTAssertTrue(cardCopy(c).contains("Finished its turn."), "the card the turn end raised stays")
        XCTAssertEqual(c.agentRowForTesting(claude.id)?.summary, "Finished its turn.")
    }

    func test_aFinishedTurn_neverTakesTheCardOfAQuestionInItsTab() throws {
        let c = makeWindow()
        let asking = try XCTUnwrap(spawned.last)
        c.handle(.splitHorizontal)
        let finishing = try XCTUnwrap(spawned.last)
        let finishingID = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        c.identifyAgentForTesting(finishingID, name: "claude")
        c.newTabForTesting()
        drainMainQueue()
        post(asking, title: AgentNotificationFixtures.claudeTitle, body: AgentNotificationFixtures.claudePermission)

        finishATurn(on: finishing)

        XCTAssertEqual(c.agentWaitForTesting(finishingID), .turnEnd, "the finished turn still waits on its row")
        XCTAssertTrue(cardCopy(c).contains(AgentNotificationFixtures.claudePermission))
        XCTAssertFalse(cardCopy(c).contains("Finished its turn."))
    }

    func test_claudesPlanApproval_waits() throws {
        let c = makeWindow()
        let claude = try backgroundPane(c)

        post(
            claude.surface, title: AgentNotificationFixtures.claudeTitle,
            body: AgentNotificationFixtures.claudePlanApproval)

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .waiting)
        XCTAssertEqual(c.agentRowForTesting(claude.id)?.state, .waiting)
    }

    func test_anyOtherClaudeNotification_waits() throws {
        let c = makeWindow()
        let claude = try backgroundPane(c)

        post(claude.surface, title: AgentNotificationFixtures.claudeTitle, body: "Refactor finished")

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .waiting)
        XCTAssertEqual(c.agentRowForTesting(claude.id)?.state, .waiting)
        XCTAssertTrue(cardCopy(c).contains("Refactor finished"))
    }

    func test_anAgentExitingCleanlyInABackgroundTab_raisesNothing() throws {
        let c = makeWindow()
        let claude = try backgroundPane(c)
        c.identifyAgentForTesting(claude.id, name: "claude")
        let tab = try XCTUnwrap(c.tabIDsForTesting(workspace: c.workspaceIDsForTesting[0]).first)

        c.notifyCommandFinishedForTesting(tab: tab, result: TerminalCommandResult(exitCode: 0, duration: 600))
        drainMainQueue()

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "quitting an agent is not news")
        XCTAssertNil(c.agentRowForTesting(claude.id))
        XCTAssertEqual(cardCount(c), 0)
    }

    func test_anAgentCrashingInABackgroundTab_waits() throws {
        let c = makeWindow()
        let claude = try backgroundPane(c)
        c.identifyAgentForTesting(claude.id, name: "claude")
        let tab = try XCTUnwrap(c.tabIDsForTesting(workspace: c.workspaceIDsForTesting[0]).first)

        c.notifyCommandFinishedForTesting(tab: tab, result: TerminalCommandResult(exitCode: 1, duration: 2))
        drainMainQueue()

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .waiting)
        XCTAssertEqual(c.agentRowForTesting(claude.id)?.state, .waiting)
        XCTAssertTrue(cardCopy(c).contains("Exited 1 after 2s."))
    }

    func test_anAgentExitSeenByThePollFirst_stillReadsAsACrash() throws {
        let c = makeWindow()
        let claude = try backgroundPane(c)
        c.identifyAgentForTesting(claude.id, name: "claude")
        let tab = try XCTUnwrap(c.tabIDsForTesting(workspace: c.workspaceIDsForTesting[0]).first)
        claude.surface.isBusy = true
        c.trackAgentExitsForTesting()
        claude.surface.isBusy = false
        c.trackAgentExitsForTesting()

        c.notifyCommandFinishedForTesting(tab: tab, result: TerminalCommandResult(exitCode: 1, duration: 2))
        drainMainQueue()

        XCTAssertEqual(c.agentRowForTesting(claude.id)?.state, .waiting, "the poll noticed first, the result decides")
        XCTAssertTrue(cardCopy(c).contains("Exited 1 after 2s."))
    }

    func test_aConfiguredAgentLaunchedByHand_joinsOnItsNotification() throws {
        var config = GeneralConfig.current
        config.ai = "pi"
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        let pi = try backgroundPane(c)

        post(pi.surface, title: "pi", body: "Wants to run swift test")

        XCTAssertEqual(
            c.attentionStateForTesting(tabIndex: 0), .waiting, "an agent with no body rules is taken at its word")
        XCTAssertEqual(c.agentRowForTesting(pi.id)?.state, .waiting)
    }

    private func pushTitle(_ title: String, from surface: RecordingSurface) {
        surface.delegate?.surface(surface, titleDidChange: title)
        drainMainQueue()
    }

    private func cardCount(_ c: WindowController) -> Int {
        guard let content = c.window.contentView else { return 0 }
        return descendants(of: content).compactMap { $0 as? ToastView }.count
    }

    func test_aBlockedCodexInABackgroundTab_raisesOneCard_andWaits() throws {
        let c = makeWindow()
        let codex = try backgroundPane(c)
        pushTitle(AgentTitleFixtures.codexWorking[0], from: codex.surface)

        pushTitle("[ . ] Action Required | Approve writing test2.txt | zen-term", from: codex.surface)

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .waiting)
        XCTAssertEqual(c.agentRowForTesting(codex.id)?.state, .waiting)
        XCTAssertEqual(cardCount(c), 1, "Codex asks through its title, so its title raises the card")
        XCTAssertTrue(cardCopy(c).contains("Approve writing test2.txt"), "the card says what Codex asks")
    }

    func test_aBlockedCodexBlinking_raisesNoSecondCard() throws {
        let c = makeWindow()
        let codex = try backgroundPane(c)
        pushTitle(AgentTitleFixtures.codexWorking[0], from: codex.surface)
        pushTitle(AgentTitleFixtures.codexBlockedOn, from: codex.surface)
        let first = try XCTUnwrap(c.waitingToastForTesting(tabIndex: 0))

        pushTitle(AgentTitleFixtures.codexBlockedOff, from: codex.surface)
        pushTitle(AgentTitleFixtures.codexBlockedOn, from: codex.surface)

        XCTAssertTrue(c.waitingToastForTesting(tabIndex: 0) === first, "one ask is one card, however its title blinks")
        XCTAssertEqual(cardCount(c), 1)
    }

    func test_theShellLeftInAFailedAgentsPane_isNotTheAgent() throws {
        let c = makeWindow()
        let pane = try backgroundPane(c)
        let failure = TerminalCommandResult(exitCode: 1, duration: 1)
        c.identifyAgentForTesting(pane.id, name: "pi")
        pane.surface.delegate?.surface(pane.surface, commandDidFinish: failure)
        drainMainQueue()

        post(pane.surface, title: "build", body: "done")

        XCTAssertFalse(cardCopy(c).contains("done"), "a shell's news never covers the crash waiting on you")
        XCTAssertEqual(
            c.agentRowForTesting(pane.id)?.summary, WindowController.commandResultMessage(failure),
            "the exited row keeps its own words")
    }

    func test_aCodexNotification_changesNoState() throws {
        let c = makeWindow()
        let codex = try backgroundPane(c)
        pushTitle(AgentTitleFixtures.codexIdle, from: codex.surface)
        pushTitle(AgentTitleFixtures.codexLaunch, from: codex.surface)

        post(codex.surface, title: "codex", body: "Approve writing test2.txt")

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "its title, not its notification, says what it wants")
        XCTAssertEqual(c.agentRowForTesting(codex.id)?.state, .idle)
        XCTAssertEqual(cardCount(c), 0)
        XCTAssertEqual(c.agentMessageForTesting(codex.id), "Approve writing test2.txt")
    }

    func test_aShellsNotification_leavesNoAgentLatch() throws {
        let c = makeWindow()
        let shell = try backgroundPane(c)

        post(shell.surface, title: "", body: "Build finished")

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .completed, "precondition: the tab reads finished")
        XCTAssertEqual(c.agentStateForTesting(shell.id), .idle, "a shell has no Agents row to latch")
    }

    func test_aShellsLongCommand_leavesNoAgentLatch() throws {
        let c = makeWindow()
        let shell = try backgroundPane(c)
        let tab = try XCTUnwrap(c.tabIDsForTesting(workspace: c.workspaceIDsForTesting[0]).first)

        c.notifyCommandFinishedForTesting(tab: tab, result: TerminalCommandResult(exitCode: 0, duration: 60))
        drainMainQueue()

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .completed, "precondition: the tab reads finished")
        XCTAssertEqual(c.agentStateForTesting(shell.id), .idle, "a shell has no Agents row to latch")
    }
}
