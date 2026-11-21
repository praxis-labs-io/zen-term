import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

// The report only reaches the chrome through a real delegate, so these drive the surface, never the handler.
@MainActor
final class AgentProgramStatusTests: WindowTestCase {
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
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
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

    private func report(
        _ state: TerminalProgramStatus.State, message: String? = nil, from surface: RecordingSurface
    ) {
        surface.delegate?.surface(
            surface, programStatusDidChange: TerminalProgramStatus(state: state, app: "claude-code", message: message))
        drainMainQueue()
    }

    private func renderedAgentRows(_ c: WindowController) -> [SidebarAgentItem] {
        c.sidebarForTesting.view.agentRowsForTesting.compactMap(\.itemForTesting)
    }

    private func tabChips(_ c: WindowController) -> [TerminalTabChip] {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return descendants(c.containerForTesting).compactMap { $0 as? TabBarView }.first?.chipsForTesting ?? []
    }

    private func firstPane(_ c: WindowController) throws -> (surface: RecordingSurface, id: SurfaceID) {
        let tab = try XCTUnwrap(c.activeTabIDForTesting.flatMap { c.controllerForTesting(tab: $0) })
        return (try XCTUnwrap(spawned.first), try XCTUnwrap(tab.surfaceIDs.first))
    }

    private func progress(_ working: Bool, from surface: RecordingSurface) {
        surface.delegate?.surface(
            surface, progressDidChange: working ? TerminalProgress(state: .indeterminate) : nil)
        drainMainQueue()
    }

    private func notify(_ body: String, from surface: RecordingSurface) {
        surface.delegate?.surface(
            surface,
            didPostNotification: TerminalNotification(title: AgentNotificationFixtures.claudeTitle, body: body))
        drainMainQueue()
    }

    func test_aClaudeWithNoReport_readsWorkingBlockedAndDone_fromItsFallback() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        c.identifyAgentForTesting(id, name: "claude")
        c.newTabForTesting()
        drainMainQueue()

        progress(true, from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .working, "an older Claude, or one under tmux, still reads working")

        notify(AgentNotificationFixtures.claudePermission, from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .blocked, "and its notification still asks")

        progress(true, from: surface)
        progress(false, from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .done, "and its progress still ends a turn")
    }

    func test_aReport_winsOverTheFallback() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        c.identifyAgentForTesting(id, name: "claude")
        progress(true, from: surface)

        report(.blocked(.permission), from: surface)

        XCTAssertEqual(c.agentStateForTesting(id), .blocked, "the report beats progress still saying working")
    }

    func test_aLateNotification_afterAnAnsweredAsk_raisesNothing() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        report(.blocked(.permission), from: surface)
        report(.working, from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .working, "precondition: the ask was answered")

        notify(AgentNotificationFixtures.claudePermission, from: surface)

        XCTAssertEqual(
            c.agentStateForTesting(id), .working,
            "Claude's notification trails its report by seconds, so it must not ask again")
    }

    func test_aBlockedReport_dotsTheRowAndTab_withinOneMainQueueTurn() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        c.newTabForTesting()
        drainMainQueue()
        report(.working, from: surface)

        report(.blocked(.permission), message: "approve Write: test.txt", from: surface)

        let row = try XCTUnwrap(renderedAgentRows(c).first { $0.id == id })
        XCTAssertEqual(row.state, .blocked, "the rendered row must show the ask, with no hold or notification wait")
        let chip = try XCTUnwrap(tabChips(c).first)
        XCTAssertTrue(chip.isDotVisibleForTesting, "the tab must show it too")
        XCTAssertEqual(chip.dotStateForTesting, .blocked)
    }

    func test_aReportsTitle_isTheRowsTitle_andItsMessageStaysWithTheRow() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)

        surface.delegate?.surface(
            surface,
            programStatusDidChange: TerminalProgramStatus(
                state: .working, app: "claude-code", message: "Reading AgentRules.swift", title: "Fix the login bug"))
        drainMainQueue()

        let row = try XCTUnwrap(renderedAgentRows(c).first { $0.id == id })
        XCTAssertEqual(row.summary, "Fix the login bug")
        XCTAssertEqual(row.message, "Reading AgentRules.swift", "the words still reach the row's tooltip")
    }

    func test_aClaudeNobodyLaunched_joinsOnItsFirstReport_byName() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)

        report(.idle, from: surface)

        let row = try XCTUnwrap(renderedAgentRows(c).first { $0.id == id })
        XCTAssertTrue(row.detail.contains("claude"), "got \(row.detail)")
    }

    func test_anAnsweredAsk_readsWorking_withItsNewWords() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        report(.blocked(.permission), message: "approve Write: test.txt", from: surface)
        XCTAssertEqual(c.agentStateForTesting(id), .blocked, "precondition: Claude is asking")

        report(.working, message: "Writing test.txt", from: surface)

        XCTAssertEqual(c.agentStateForTesting(id), .working)
        XCTAssertEqual(c.agentMessageForTesting(id), "Writing test.txt")
    }

    func test_typingAtAClaudePrompt_leavesItWaiting() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        report(.blocked(.permission), from: surface)

        c.answerTypedAgent()

        XCTAssertEqual(c.agentStateForTesting(id), .blocked, "an arrow key at the prompt answers nothing")
    }

    func test_aDrawersReport_reachesTheAgent() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first)
        drainMainQueue()
        let tab = try XCTUnwrap(c.activeTabIDForTesting.flatMap { c.controllerForTesting(tab: $0) })
        let id = try XCTUnwrap(tab.drawerSurfaceIDs.right)

        report(.working, message: "Reading AgentRules.swift", from: drawer)

        XCTAssertEqual(c.agentStateForTesting(id), .working)
        XCTAssertEqual(c.agentMessageForTesting(id), "Reading AgentRules.swift")
    }

    func test_aFloatsReport_reachesTheAgent() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let float = try XCTUnwrap(spawned.dropFirst(before).first)
        let id = try XCTUnwrap(c.floatsForTesting.surfaceID(ToolFloat.scratch.id))

        report(.working, from: float)

        XCTAssertEqual(c.agentStateForTesting(id), .working)
    }

    func test_aClearedReport_handsBackToTheFallback() throws {
        let c = makeWindow()
        let (surface, id) = try firstPane(c)
        report(.working, from: surface)

        surface.delegate?.surface(surface, programStatusDidChange: nil)
        drainMainQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(AgentStateTracker.idleHold + 0.3))

        XCTAssertEqual(c.agentStateForTesting(id), .idle, "with no report, the fallback reads its cleared progress")
    }
}
