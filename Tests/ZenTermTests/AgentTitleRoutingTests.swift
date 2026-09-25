import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

// The title only reaches the chrome through a real delegate, so these drive the surface, never the handler.
@MainActor
final class AgentTitleRoutingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let originalPresence = WindowController.isPresent
    private var originalConfig: GeneralConfig!

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalConfig = GeneralConfig.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        WindowController.isPresent = originalPresence
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        c.mountAndStart()
        controller = c
        return c
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func push(_ title: String, from surface: RecordingSurface) {
        surface.delegate?.surface(surface, titleDidChange: title)
        drainMainQueue()
    }

    private func activeTab(_ c: WindowController) throws -> TabController {
        try XCTUnwrap(c.activeTabIDForTesting.flatMap { c.controllerForTesting(tab: $0) })
    }

    private func renderedAgentRows(_ c: WindowController) -> [SidebarAgentItem] {
        c.sidebarForTesting.view.agentRowsForTesting.compactMap(\.itemForTesting)
    }

    private func firstPane(_ c: WindowController) throws -> (surface: RecordingSurface, id: SurfaceID) {
        (try XCTUnwrap(spawned.first), try XCTUnwrap(try activeTab(c).surfaceIDs.first))
    }

    private func notify(_ notification: TerminalNotification, from surface: RecordingSurface) {
        surface.delegate?.surface(surface, didPostNotification: notification)
        drainMainQueue()
    }

    private func firstClaudeAsking(_ c: WindowController) throws -> (surface: RecordingSurface, id: SurfaceID) {
        let (surface, id) = try firstPane(c)
        c.identifyAgentForTesting(id, name: "claude")
        surface.delegate?.surface(surface, progressDidChange: TerminalProgress(state: .indeterminate))
        drainMainQueue()
        push(AgentTitleFixtures.claudeAsking, from: surface)
        notify(TerminalNotification(title: "Claude Code", body: "Claude needs your permission"), from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .waiting, "precondition: Claude is asking")
        return (surface, id)
    }

    func test_aDrawersTitle_reachesTheAgent() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first, "opening the drawer spawns its surface")
        drainMainQueue()
        let id = try XCTUnwrap(try activeTab(c).drawerSurfaceIDs.right)
        c.identifyAgentForTesting(id, name: "codex")

        push(AgentTitleFixtures.codexWorking[0], from: drawer)

        XCTAssertEqual(
            c.agentStateForTesting(id), .working,
            "every workspace recipe puts its agent in a drawer, so this is the path that matters")
    }

    func test_anUnfocusedSplitsTitle_reachesTheAgent() throws {
        let c = makeWindow()
        c.handle(.splitVertical)
        drainMainQueue()
        let ids = try activeTab(c).surfaceIDs
        XCTAssertEqual(ids.count, 2, "got \(ids)")
        let unfocused = try XCTUnwrap(ids.first { $0 != c.focusedSurfaceIDForTesting })
        let surface = try XCTUnwrap(c.terminalSurfaceForTesting(unfocused) as? RecordingSurface)
        c.identifyAgentForTesting(unfocused, name: "codex")

        push(AgentTitleFixtures.codexWorking[0], from: surface)

        XCTAssertEqual(
            c.agentStateForTesting(unfocused), .working,
            "an agent working in a background split still reports")
    }

    func test_aCodexPromptInADrawer_readsWaiting() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first)
        drainMainQueue()
        let id = try XCTUnwrap(try activeTab(c).drawerSurfaceIDs.right)
        c.identifyAgentForTesting(id, name: "codex")

        push(AgentTitleFixtures.codexBlockedOn, from: drawer)

        XCTAssertEqual(c.agentStateForTesting(id), .waiting)
    }

    func test_aClaudeTurnInADrawer_showsItsToolName() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first)
        drainMainQueue()
        let id = try XCTUnwrap(try activeTab(c).drawerSurfaceIDs.right)
        c.identifyAgentForTesting(id, name: "claude")
        drawer.delegate?.surface(drawer, progressDidChange: TerminalProgress(state: .indeterminate))
        drainMainQueue()

        push(AgentTitleFixtures.claudeWorking, from: drawer)

        XCTAssertEqual(c.agentMessageForTesting(id), "Multiple choice question tool")
    }

    func test_aCodexNobodyLaunched_joinsOnItsOwnTitle() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)

        push(AgentTitleFixtures.codexWorking[0], from: surface)

        XCTAssertEqual(
            c.agentRowForTesting(id)?.detail.contains("codex"), true,
            "codex emits no progress and its notification is unreliable, so the title is its only way in")
        XCTAssertEqual(c.agentStateForTesting(id), .working)
    }

    func test_aHandLaunchedCodex_thenAsking_readsWaiting() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        push(AgentTitleFixtures.codexWorking[0], from: surface)

        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        XCTAssertEqual(c.agentStateForTesting(id), .waiting)
    }

    func test_typingAtABlockedCodex_leavesItWaiting() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        push(AgentTitleFixtures.codexWorking[0], from: surface)
        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        c.answerTypedAgent()

        XCTAssertEqual(c.agentStateForTesting(id), .waiting, "an arrow key at the prompt answers nothing")
    }

    func test_aBlockedCodexBackAtWork_isAnswered() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        push(AgentTitleFixtures.codexWorking[0], from: surface)
        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        push(AgentTitleFixtures.codexWorking[1], from: surface)

        XCTAssertEqual(c.agentStateForTesting(id), .working, "its spinner coming back is the answer")
    }

    func test_aBlockedCodexGoingQuiet_isAnswered() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        push(AgentTitleFixtures.codexWorking[0], from: surface)
        push(AgentTitleFixtures.codexBlockedOn, from: surface)

        push(AgentTitleFixtures.codexIdle, from: surface)

        XCTAssertEqual(c.agentStateForTesting(id), .idle, "a denied prompt leaves the title without a spinner")
    }

    func test_aCodexThatAskedByNotification_isAnsweredByItsNextTurn() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        push(AgentTitleFixtures.codexIdle, from: surface)
        c.identifyAgentForTesting(id, name: "codex")
        notify(TerminalNotification(title: "", body: "Approve writing test2.txt"), from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .waiting, "precondition: it asked without its prompt title")

        push(AgentTitleFixtures.codexWorking[0], from: surface)

        XCTAssertEqual(
            c.agentStateForTesting(id), .working, "a wait that never passed through the prompt title still ends")
    }

    func test_typingAtAClaudePrompt_leavesItWaiting() throws {
        let c = makeWindow()
        let id = try firstClaudeAsking(c).id

        c.answerTypedAgent()

        XCTAssertEqual(c.agentStateForTesting(id), .waiting, "an arrow key at the prompt answers nothing")
    }

    func test_aClaudePrompt_isAnsweredWhenItsSpinnerComesBack() throws {
        let c = makeWindow()
        let (surface, id) = try firstClaudeAsking(c)

        push(AgentTitleFixtures.claudeAnswered, from: surface)

        XCTAssertEqual(c.agentStateForTesting(id), .working)
        XCTAssertEqual(c.agentMessageForTesting(id), "Create test.txt", "the row reads the tool it went back to")
    }

    func test_aCustomAgent_isStillAnsweredByTyping() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        c.identifyAgentForTesting(id, name: "aider")
        notify(TerminalNotification(title: "", body: "Apply these edits?"), from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .waiting)

        c.answerTypedAgent()

        XCTAssertEqual(
            c.agentStateForTesting(id), .idle, "an agent with no answer signal of its own is answered by a key")
    }

    func test_aTitleFromASurfaceThatIsNoAgent_changesNothing() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)

        push("npm run build", from: surface)

        XCTAssertNil(c.agentRowForTesting(id), "a shell is not an agent")
        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0))
    }

    func test_aWorkingCodexWhoseTaskSaysActionRequired_isNotAsking() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)

        push("⠹ Fix the Action Required banner | drucial", from: surface)

        XCTAssertEqual(c.agentStateForTesting(id), .working, "the prompt is the title's head, not a phrase in the task")
    }

    func test_aCodexJoinedByItsLaunchTitle_isListedAtOnce() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)

        push(AgentTitleFixtures.codexLaunch, from: surface)

        XCTAssertEqual(renderedAgentRows(c).map(\.id), [id], "an idle Codex at its prompt is still an agent")
    }

    func test_aHandLaunchedClaude_isListedByNameAtLaunch() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)

        push(AgentTitleFixtures.claudeIdle, from: surface)

        let row = try XCTUnwrap(renderedAgentRows(c).first { $0.id == id }, "claude sends no progress until a turn")
        XCTAssertTrue(row.detail.contains("claude"), "got \(row.detail)")
    }

    func test_aCodexRelaunchedAfterExitingMidTurn_readsWorking() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        push(AgentTitleFixtures.codexWorking[0], from: surface)
        surface.isBusy = true
        c.trackAgentExitsForTesting()
        surface.isBusy = false
        c.trackAgentExitsForTesting()
        XCTAssertNil(c.agentRowForTesting(id), "precondition: the interrupted Codex left")

        push(AgentTitleFixtures.codexLaunch, from: surface)
        push(AgentTitleFixtures.codexWorking[1], from: surface)

        XCTAssertEqual(
            c.agentStateForTesting(id), .working, "the new session starts clean, not where the last one stopped")
    }

    func test_aCodexTurnEnd_landsWithoutWaitingForThePoll() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        push(AgentTitleFixtures.codexWorking[0], from: surface)

        push(AgentTitleFixtures.codexIdle, from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .working, "precondition: one quiet title is held")
        let settled = expectation(description: "hold elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentStateTracker.idleHold + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertNotEqual(c.agentStateForTesting(id), .working, "codex sends nothing after its idle title")
    }

    func test_claudesIdleFlickerMidTurn_keepsItsToolName() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        c.identifyAgentForTesting(id, name: "claude")
        surface.delegate?.surface(surface, progressDidChange: TerminalProgress(state: .indeterminate))
        drainMainQueue()
        push(AgentTitleFixtures.claudeWorking, from: surface)

        push(AgentTitleFixtures.claudeIdle, from: surface)

        XCTAssertEqual(c.agentMessageForTesting(id), "Multiple choice question tool")
    }

    func test_aFloatsTitle_reachesTheAgent() throws {
        var config = GeneralConfig.current
        config.floats = [
            ToolFloat(
                id: "btop", order: 0, title: "btop", icon: ToolFloatParser.defaultIcon,
                command: "btop", dir: nil, widthFraction: 0.85, heightFraction: 0.85,
                requiresGitRepo: false, persist: .window,
                toggle: Chord(command: true, shift: true, key: "b"))
        ]
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let float = try XCTUnwrap(spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "btop"] })
        let id = try XCTUnwrap(c.floatsForTesting.surfaceID("btop"))

        push(AgentTitleFixtures.codexWorking[0], from: float)

        XCTAssertEqual(c.agentStateForTesting(id), .working)
    }
}
