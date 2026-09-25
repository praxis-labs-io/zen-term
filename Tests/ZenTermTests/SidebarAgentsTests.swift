import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SidebarAgentsTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var root: URL!

    private struct Agent {
        let surface: RecordingSurface
        let id: SurfaceID
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        SidebarController.resetLastChoiceForTesting()
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
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controllers = []
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        TooltipPresenter.shared.dismissForTesting()
        SidebarController.resetLastChoiceForTesting()
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func focusedAgent(_ c: WindowController) throws -> Agent {
        Agent(surface: try XCTUnwrap(spawned.last), id: try XCTUnwrap(c.focusedSurfaceIDForTesting))
    }

    private func split(_ c: WindowController) throws -> Agent {
        let before = c.focusedSurfaceIDForTesting
        c.window.contentView?.layoutSubtreeIfNeeded()
        c.handle(spawned.count.isMultiple(of: 2) ? .splitHorizontal : .splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let agent = try focusedAgent(c)
        XCTAssertNotEqual(agent.id, before, "precondition: the split takes focus")
        return agent
    }

    private func recipe(_ title: String, right: String?) -> Workspace {
        let folder = root.appendingPathComponent(title, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Workspace(
            title: title, path: folder, main: nil, right: right, bottom: nil, focus: .main, env: [:])
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func notify(_ agent: Agent, _ body: String, title: String = "pi") {
        agent.surface.delegate?.surface(
            agent.surface, didPostNotification: TerminalNotification(title: title, body: body))
        drainMainQueue()
    }

    private func progress(_ agent: Agent, working: Bool) {
        agent.surface.delegate?.surface(
            agent.surface,
            progressDidChange: working ? TerminalProgress(state: .indeterminate, fraction: nil) : nil)
        drainMainQueue()
    }

    private func rows(_ c: WindowController) -> [SidebarAgentRow] {
        c.sidebarForTesting.view.agentRowsForTesting
    }

    private func section(_ c: WindowController) -> [NSView] {
        c.sidebarForTesting.view.agentSectionForTesting
    }

    private func waitingRow(_ c: WindowController) -> SidebarWaitingElsewhereRow? {
        c.sidebarForTesting.view.waitingElsewhereRowForTesting
    }

    // What AppDelegate wires for real. Raising the window is AppKit's, and belongs to the runbook.
    private func wireJump(from asking: WindowController, to others: [WindowController]) {
        asking.revealWaitingAgentElsewhere = { window in
            guard let other = others.first(where: { $0.windowID == window }) else { return false }
            return other.revealLongestWaitingAgent()
        }
    }

    private func items(_ c: WindowController) -> [SidebarAgentItem] {
        rows(c).compactMap(\.itemForTesting)
    }

    private func focus(_ agent: Agent, in c: WindowController) {
        while c.focusedSurfaceIDForTesting != agent.id { c.handle(.nextPane) }
    }

    private func click(_ row: NSView) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        row.mouseDown(with: event)
    }

    private func hover(_ row: SidebarAgentRow, in c: WindowController) throws {
        TooltipPresenter.shared.dismissForTesting()
        row.mouseEntered(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1)))
    }

    private func unhover(_ row: SidebarAgentRow, in c: WindowController) throws {
        row.mouseExited(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1)))
    }

    private func presentedTooltip() throws -> ChromeTooltip {
        let deadline = Date().addingTimeInterval(2)
        while TooltipPresenter.shared.tooltipForTesting == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return try XCTUnwrap(TooltipPresenter.shared.tooltipForTesting, "no tooltip appeared on hover")
    }

    private func arrow(_ code: UInt16, in c: WindowController) -> NSEvent {
        let text = code == 125 ? "\u{F701}" : "\u{F700}"
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: c.window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    private func returnKey(in c: WindowController) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: c.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    func test_noAgents_hidesTheSection() {
        let c = makeWindow()

        XCTAssertTrue(c.sidebarForTesting.view.agentsAreHiddenForTesting)
        XCTAssertTrue(rows(c).isEmpty)
    }

    func test_rowsSortWaitingThenWorkingThenDoneThenIdle_asStatesChange() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        let second = try split(c)
        let third = try split(c)
        _ = try split(c)

        progress(third, working: true)
        progress(third, working: false)
        progress(second, working: true)
        notify(first, "Wants to run swift test")

        XCTAssertEqual(items(c).map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(items(c).map(\.state), [.waiting, .working, .done])
        XCTAssertEqual(items(c).map(\.summary), ["Wants to run swift test", "Working", "Done"])
        XCTAssertFalse(c.sidebarForTesting.view.agentsAreHiddenForTesting)

        notify(second, "Asks before the backfill")
        XCTAssertEqual(items(c).map(\.id), [first.id, second.id, third.id], "the longest waiting reads first")

        focus(first, in: c)
        c.answerTypedAgent()
        XCTAssertEqual(items(c).map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(items(c).map(\.state), [.waiting, .done, .idle])
        XCTAssertEqual(items(c).last?.summary, "Idle", "an answered question does not linger")

        progress(third, working: true)
        XCTAssertEqual(items(c).map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(items(c).map(\.state), [.waiting, .working, .idle])
    }

    func test_anAgentWaitingInAnUnfocusedSplit_staysWaitingUntilItIsAnswered() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        _ = try split(c)

        notify(first, "Wants to run swift test")

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "the tab number keeps using tab activeness")
        XCTAssertEqual(items(c).map(\.state), [.waiting])

        _ = try split(c)
        XCTAssertEqual(items(c).map(\.state), [.waiting], "focusing another pane does not answer it")

        focus(first, in: c)
        XCTAssertEqual(items(c).map(\.state), [.waiting], "focusing it back is not answering it")

        c.answerTypedAgent()
        XCTAssertEqual(items(c).map(\.state), [.idle])
        XCTAssertEqual(
            rows(c).first?.fillForTesting, NSColor.clear.cgColor, "only the workspace row reads as active")
    }

    func test_aLaunchedAgent_isListedIdleFromLaunch_andOtherProgramsAreNot() throws {
        let c = makeWindow()

        c.openWorkspaceForTesting(recipe("zen-review", right: "claude --resume"))
        c.openWorkspaceForTesting(recipe("notes", right: "vim"))

        XCTAssertEqual(items(c).map(\.detail), ["zen-review · claude"])
        XCTAssertEqual(items(c).map(\.state), [.idle])
    }

    func test_aShellsNotification_joinsNothing_whileOneNamingAnAgent_joinsUnderThatName() throws {
        let c = makeWindow()
        let shell = try focusedAgent(c)
        let second = try split(c)
        _ = try split(c)

        notify(shell, "Build finished", title: "")
        notify(second, "Claude needs your permission", title: "Claude Code")

        XCTAssertEqual(items(c).map(\.detail), ["Workspace 1 · Claude Code"])
    }

    func test_anAgentThatWorksBeforeItAsks_takesTheNameItsNotificationCarries() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)

        progress(agent, working: true)
        XCTAssertEqual(items(c).map(\.detail), ["Workspace 1 · agent"], "precondition: joined unnamed")
        notify(agent, "Claude needs your permission", title: "Claude Code")

        XCTAssertEqual(items(c).map(\.detail), ["Workspace 1 · Claude Code"])
    }

    func test_anAgentLeaves_whenItsSurfaceFallsIdle_notBeforeItWasBusy() throws {
        let c = makeWindow()
        c.openWorkspaceForTesting(recipe("zen-review", right: "claude"))
        let drawer = try XCTUnwrap(spawned.last)

        c.trackAgentExitsForTesting()
        XCTAssertEqual(items(c).count, 1, "not busy yet is not an exit")

        drawer.isBusy = true
        c.trackAgentExitsForTesting()
        drawer.isBusy = false
        c.trackAgentExitsForTesting()

        XCTAssertTrue(items(c).isEmpty)
        XCTAssertTrue(c.sidebarForTesting.view.agentsAreHiddenForTesting)
    }

    func test_anAgentThatExitsBeforeTheFirstBusyPoll_leavesTheList() throws {
        let c = makeWindow()
        c.openWorkspaceForTesting(recipe("zen-review", right: "claude --resume"))
        let drawer = try XCTUnwrap(spawned.last)
        XCTAssertEqual(items(c).count, 1, "precondition: listed at launch, never polled busy")

        drawer.delegate?.surface(drawer, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 0.2))
        drainMainQueue()

        XCTAssertTrue(items(c).isEmpty)
    }

    func test_anAgentExitingNonZero_staysUntilItIsAnswered() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        let second = try split(c)
        notify(first, "Wants to run swift test")
        focus(first, in: c)
        c.answerTypedAgent()
        focus(second, in: c)
        XCTAssertEqual(items(c).map(\.state), [.idle], "precondition: nothing latched")
        first.surface.isBusy = true
        c.trackAgentExitsForTesting()

        let result = TerminalCommandResult(exitCode: 1, duration: 192)
        first.surface.delegate?.surface(first.surface, commandDidFinish: result)
        drainMainQueue()
        first.surface.isBusy = false
        c.trackAgentExitsForTesting()

        XCTAssertEqual(items(c).map(\.state), [.failed])
        XCTAssertEqual(items(c).first?.summary, WindowController.commandResultMessage(result))

        focus(first, in: c)
        c.answerTypedAgent()
        XCTAssertTrue(items(c).isEmpty)
    }

    func test_anAgentThatExitsMidTurn_leavesTheList() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        progress(agent, working: true)
        agent.surface.isBusy = true
        c.trackAgentExitsForTesting()
        XCTAssertEqual(items(c).map(\.state), [.working], "precondition")

        agent.surface.isBusy = false
        c.trackAgentExitsForTesting()

        XCTAssertTrue(items(c).isEmpty)
        XCTAssertEqual(c.agentStateForTesting(agent.id), .idle)
    }

    func test_anAgentThatAskedThenExitsNonZero_readsExited() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        _ = try split(c)
        notify(first, "Wants to run swift test")
        XCTAssertEqual(items(c).map(\.state), [.waiting], "precondition")

        let result = TerminalCommandResult(exitCode: 1, duration: 3)
        first.surface.delegate?.surface(first.surface, commandDidFinish: result)
        drainMainQueue()

        XCTAssertEqual(items(c).map(\.state), [.failed])
    }

    func test_anAgentStoppedWithCtrlC_doesNotReadAsFailed() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        _ = try split(c)
        notify(first, "Wants to run swift test")
        XCTAssertEqual(items(c).map(\.state), [.waiting], "precondition")

        let result = TerminalCommandResult(exitCode: 130, duration: 3)
        first.surface.delegate?.surface(first.surface, commandDidFinish: result)
        drainMainQueue()

        XCTAssertNotEqual(items(c).map(\.state), [.failed], "Ctrl-C is a deliberate stop, not a failure")
        XCTAssertEqual(c.agentStateForTesting(first.id), .idle, "and it raises nothing at you")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func showsToast(_ message: String, in c: WindowController) -> Bool {
        guard let content = c.window.contentView else { return false }
        return descendants(of: content).contains { ($0 as? NSTextField)?.stringValue == message }
    }

    private static let nothingWaitingMessage =
        "No agent in this window is asking for you.\nThe sidebar lists the ones that are."
    private static let waitingElsewhereMessage =
        "Nothing in this window is asking for you.\nThe sidebar row takes you there."

    func test_theChord_goesToTheAgentThatHasWaitedLongest() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        let second = try split(c)
        notify(first, "Wants to run swift test")
        notify(second, "Wants to edit a file")
        XCTAssertEqual(c.focusedSurfaceIDForTesting, second.id, "precondition: the split holds focus")

        c.handle(.nextWaitingAgent)

        XCTAssertEqual(c.focusedSurfaceIDForTesting, first.id, "the longest wait comes first")
    }

    func test_theChord_skipsTheAgentYouAreAlreadyOn() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        let second = try split(c)
        WindowController.isPresent = { _ in false }
        notify(first, "Wants to run swift test")
        notify(second, "Wants to edit a file")
        focus(first, in: c)
        XCTAssertEqual(
            c.focusedSurfaceIDForTesting, first.id, "precondition: you are on the head of the queue")
        XCTAssertEqual(
            items(c).filter { $0.state == .waiting }.map(\.id), [first.id, second.id],
            "precondition: both are still waiting, and the one you are on reads first")

        c.handle(.nextWaitingAgent)

        XCTAssertEqual(
            c.focusedSurfaceIDForTesting, second.id,
            "landing where you already are would read as the chord doing nothing")
    }

    func test_theChord_reachesEveryWaitingAgent_notJustTwo() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        let second = try split(c)
        let third = try split(c)
        WindowController.isPresent = { _ in false }
        notify(first, "Wants to run swift test")
        notify(second, "Wants to edit a file")
        notify(third, "Wants to push")
        let queue = items(c).filter { $0.state == .waiting }.map(\.id)
        XCTAssertEqual(queue.count, 3, "precondition: three agents are waiting")

        var visited: [SurfaceID] = []
        for _ in 0..<3 {
            c.handle(.nextWaitingAgent)
            visited.append(try XCTUnwrap(c.focusedSurfaceIDForTesting))
        }

        XCTAssertEqual(
            Set(visited), Set(queue),
            "stepping from the focused agent reaches all three; picking the first unfocused one ping-pongs between two")
    }

    func test_withNothingWaiting_theChordSaysSoRatherThanMovingYou() throws {
        let c = makeWindow()
        let only = try focusedAgent(c)

        c.handle(.nextWaitingAgent)

        XCTAssertEqual(c.focusedSurfaceIDForTesting, only.id, "nothing to jump to, so nothing moves")
        XCTAssertTrue(showsToast(Self.nothingWaitingMessage, in: c))
    }

    func test_withNothingHereButSomethingElsewhere_theChordDoesNotClaimNothingIsWaiting() throws {
        let c = makeWindow()
        _ = try focusedAgent(c)
        let other = c.windowID + 1_000
        AttentionCenter.shared.update(windowID: other, waitingCount: 1, since: Date())
        addTeardownBlock { AttentionCenter.shared.forget(windowID: other) }

        c.handle(.nextWaitingAgent)

        XCTAssertTrue(showsToast(Self.waitingElsewhereMessage, in: c))
        XCTAssertFalse(showsToast(Self.nothingWaitingMessage, in: c), "it would be lying")
    }

    func test_theRefusalCopy_fitsTheToastWrapColumn() {
        for message in [Self.nothingWaitingMessage, Self.waitingElsewhereMessage] {
            for line in message.split(separator: "\n") {
                let width = (String(line) as NSString)
                    .size(withAttributes: [.font: ToastView.messageFont]).width
                XCTAssertLessThanOrEqual(
                    width, ToastView.messageMaxWidth,
                    "wraps at \(Int(width))pt > \(Int(ToastView.messageMaxWidth))pt: \(line)")
            }
        }
    }

    func test_clickingAnAgent_inAnotherWorkspace_switchesAndFocusesItsPane() throws {
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        c.openWorkspaceForTesting(recipe("zen-review", right: nil))
        let target = c.activeWorkspaceIDForTesting
        let agent = try focusedAgent(c)
        _ = try split(c)
        notify(agent, "Wants to run swift test")
        c.activateWorkspaceForTesting(home)

        try click(try XCTUnwrap(rows(c).first))

        XCTAssertEqual(c.activeWorkspaceIDForTesting, target)
        XCTAssertEqual(c.focusedSurfaceIDForTesting, agent.id)
        XCTAssertEqual(
            items(c).map(\.state), [.waiting], "the jump takes you to the prompt, it does not answer it")
    }

    func test_clickingAnAgent_inAClosedDrawer_opensAndFocusesIt() throws {
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        c.openWorkspaceForTesting(recipe("zen-review", right: "claude"))
        let tab = try XCTUnwrap(c.activeTabIDForTesting)
        let drawer = try XCTUnwrap(c.controllerForTesting(tab: tab)?.drawerSurfaceIDs.right)
        c.handle(.toggleRightDrawer)
        XCTAssertEqual(c.controllerForTesting(tab: tab)?.overlayState.isRightOpen, false, "precondition")
        c.activateWorkspaceForTesting(home)

        try click(try XCTUnwrap(rows(c).first))

        XCTAssertEqual(c.controllerForTesting(tab: tab)?.overlayState.isRightOpen, true)
        XCTAssertEqual(c.focusedSurfaceIDForTesting, drawer)
    }

    func test_clickingAnAgent_inAHiddenFloat_opensAndFocusesIt() throws {
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
        c.handle(.toggleToolFloat("btop"))
        XCTAssertNil(c.floatsForTesting.activeID, "precondition: the float is hidden")
        float.delegate?.surface(float, didPostNotification: TerminalNotification(title: "pi", body: "Needs input"))
        drainMainQueue()

        try click(try XCTUnwrap(rows(c).first))

        XCTAssertEqual(c.floatsForTesting.activeID, "btop")
        XCTAssertTrue(c.window.firstResponder === float.view)
    }

    func test_clickingAnAgent_inADirectoryFloatFromAnotherWorkspace_keepsThatAgent() throws {
        var config = GeneralConfig.current
        config.floats = [
            ToolFloat(
                id: "claude", order: 0, title: "claude", icon: ToolFloatParser.defaultIcon,
                command: "claude", dir: nil, widthFraction: 0.85, heightFraction: 0.85,
                requiresGitRepo: false, persist: .directory,
                toggle: Chord(command: true, shift: true, key: "b"))
        ]
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        c.floatsForTesting.resolveRepoRoot = { $1($0) }
        c.openWorkspaceForTesting(recipe("zen-review", right: nil))
        c.handle(.toggleToolFloat("claude"))
        let float = try XCTUnwrap(spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "claude"] })
        c.handle(.toggleToolFloat("claude"))
        c.openWorkspaceForTesting(recipe("notes", right: nil))
        XCTAssertEqual(items(c).count, 1, "precondition: the float's agent is listed")

        try click(try XCTUnwrap(rows(c).first))

        XCTAssertFalse(float.terminated)
        XCTAssertEqual(c.floatsForTesting.activeID, "claude")
        XCTAssertTrue(c.window.firstResponder === float.view)
    }

    func test_arrows_continueFromTheWorkspaceRowsIntoTheAgents_andReturnJumps() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        let second = try split(c)
        notify(first, "Wants to run swift test")
        progress(second, working: true)
        _ = try split(c)
        let workspaceRows = c.sidebarForTesting.view.rowsForTesting
        let agentRows = rows(c)
        XCTAssertEqual(agentRows.count, 2, "precondition")

        c.sidebarForTesting.focusActiveRow()
        XCTAssertTrue(c.window.firstResponder === workspaceRows[0])

        c.window.sendEvent(arrow(125, in: c))
        XCTAssertTrue(c.window.firstResponder === agentRows[0], "↓ leaves Workspaces for Agents")
        XCTAssertEqual(agentRows[0].fillForTesting, Theme.current.chrome.selectionFill.cgColor)
        c.window.sendEvent(arrow(125, in: c))
        XCTAssertTrue(c.window.firstResponder === agentRows[1])
        c.window.sendEvent(arrow(125, in: c))
        XCTAssertTrue(c.window.firstResponder === agentRows[1], "↓ stops at the last agent")
        c.window.sendEvent(arrow(126, in: c))
        c.window.sendEvent(arrow(126, in: c))
        XCTAssertTrue(c.window.firstResponder === workspaceRows[0], "↑ climbs back into Workspaces")

        c.window.sendEvent(arrow(125, in: c))
        c.window.sendEvent(returnKey(in: c))

        XCTAssertEqual(c.focusedSurfaceIDForTesting, first.id)
        XCTAssertFalse(c.sidebarForTesting.hasFocus)
    }

    func test_aWorkspaceWithAnAgentWaiting_showsTheDot_untilItsTabIsVisited() throws {
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        c.openWorkspaceForTesting(recipe("zen-review", right: nil))
        let review = c.activeWorkspaceIDForTesting
        let agent = try focusedAgent(c)
        c.activateWorkspaceForTesting(home)
        let rows = c.sidebarForTesting.view.rowsForTesting

        progress(agent, working: true)
        XCTAssertEqual(rows.map(\.showsAttentionForTesting), [false, false], "working is not waiting")

        notify(agent, "Wants to run swift test")
        XCTAssertEqual(rows.map(\.showsAttentionForTesting), [false, true])
        XCTAssertEqual(rows[1].accessibilityValue() as? String, "Agent waiting")

        c.activateWorkspaceForTesting(review)
        XCTAssertEqual(rows.map(\.showsAttentionForTesting), [false, false])
        XCTAssertNil(rows[1].accessibilityValue())
    }

    func test_anAgentRowBornUnderACard_takesNoHover() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        c.handle(.openSettings)
        notify(agent, "Wants to run swift test")

        let row = try XCTUnwrap(rows(c).first, "the agent joins the list while the card is open")
        row.mouseEntered(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))

        XCTAssertNotEqual(
            row.fillForTesting, Theme.current.chrome.fill(.hover).cgColor,
            "a row built while the sidebar is covered starts suppressed like the rows already there")
    }

    func test_whileACardCoversTheSidebar_agentRowsTakeNoHover() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        notify(agent, "Wants to run swift test")
        let row = try XCTUnwrap(rows(c).first)
        let moved = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        c.handle(.openSettings)
        row.mouseEntered(with: moved)

        XCTAssertNotEqual(
            row.fillForTesting, Theme.current.chrome.fill(.hover).cgColor,
            "a card covers the agents without taking their tracking events")

        c.handle(.openSettings)
        row.mouseEntered(with: moved)

        XCTAssertEqual(row.fillForTesting, Theme.current.chrome.fill(.hover).cgColor, "hover comes back")
    }
    func test_aCardOpenedFromAnAgentRow_handsFocusBackToIt() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        notify(agent, "Wants to run swift test")
        let row = try XCTUnwrap(rows(c).first)
        row.takeKeyboardFocus()
        XCTAssertTrue(c.window.firstResponder === row, "precondition: the agent row holds focus")

        c.handle(.openSettings)
        c.handle(.openSettings)

        XCTAssertTrue(c.window.firstResponder === row, "focus goes back to the agent row it was opened from")
    }

    func test_anAgentWaitingInAnotherWindow_readsHere_andClearsWhenItIsAnswered() throws {
        let a = makeWindow()
        let b = makeWindow()
        let agent = try focusedAgent(b)
        b.newTabForTesting()

        XCTAssertNil(waitingRow(a), "nothing waits anywhere yet")

        notify(agent, "Wants to run swift test")

        XCTAssertEqual(waitingRow(a)?.textForTesting, "1 waiting in another window")
        XCTAssertNil(waitingRow(b), "a window never counts its own")
        XCTAssertFalse(a.sidebarForTesting.view.agentsAreHiddenForTesting)
        XCTAssertTrue(rows(a).isEmpty, "the section is up for the row alone")

        b.selectTabForTesting(index: 0)

        XCTAssertNil(waitingRow(a), "answered there, gone here")
        XCTAssertTrue(a.sidebarForTesting.view.agentsAreHiddenForTesting)
    }

    func test_anAgentAskingInAWindowYouAreNotIn_waits_thoughItsPaneIsOnScreen() throws {
        let a = makeWindow()
        let b = makeWindow()
        let agent = try focusedAgent(b)
        WindowController.isPresent = { [weak b] window in window !== b?.window }

        notify(agent, "Wants to run swift test")

        XCTAssertEqual(
            waitingRow(a)?.textForTesting, "1 waiting in another window",
            "a pane you can see from another window has not been seen")
        XCTAssertEqual(b.attentionStateForTesting(tab: try XCTUnwrap(b.activeTabIDForTesting)), .waiting)
    }

    func test_answeringByFocusingThePane_clearsTheRowInTheOtherWindow() throws {
        let a = makeWindow()
        let b = makeWindow()
        let agent = try focusedAgent(b)
        _ = try split(b)
        WindowController.isPresent = { [weak b] window in window !== b?.window }

        notify(agent, "Wants to run swift test")
        XCTAssertEqual(waitingRow(a)?.textForTesting, "1 waiting in another window", "precondition")

        WindowController.isPresent = { _ in true }
        focus(agent, in: b)

        XCTAssertNil(
            waitingRow(a), "focusing the pane answers it, and the count other windows read has to follow")
    }

    func test_answeringByFocusingThePane_clearsTheWorkspaceDotToo() throws {
        let a = makeWindow()
        let b = makeWindow()
        let agent = try focusedAgent(b)
        _ = try split(b)
        WindowController.isPresent = { [weak b] window in window !== b?.window }

        notify(agent, "Wants to run swift test")
        let row = try XCTUnwrap(b.sidebarForTesting.view.rowsForTesting.first)
        XCTAssertTrue(row.showsAttentionForTesting, "precondition: its own workspace says something waits")
        XCTAssertNotNil(waitingRow(a), "precondition")

        WindowController.isPresent = { _ in true }
        focus(agent, in: b)

        XCTAssertFalse(
            row.showsAttentionForTesting, "answering by focus has to repaint the row that carried the dot")
        XCTAssertNil(waitingRow(a))
    }

    func test_twoAgentsInDifferentTabsOfAnotherWindow_countAsTwo() throws {
        let a = makeWindow()
        let b = makeWindow()
        let first = try focusedAgent(b)
        b.newTabForTesting()
        let second = try focusedAgent(b)
        WindowController.isPresent = { [weak b] window in window !== b?.window }

        notify(first, "Wants to run swift test")
        notify(second, "Asks before the backfill")

        XCTAssertEqual(waitingRow(a)?.textForTesting, "2 waiting in another window")
    }

    func test_aStaleRow_raisesNothing() throws {
        let b = makeWindow()
        var raised = false

        XCTAssertFalse(b.revealLongestWaitingAgent { raised = true })
        XCTAssertFalse(raised, "nothing waits there, so nothing is disturbed")
    }

    func test_theRowRefusesAWorktree_theWayAnAgentRowDoes() throws {
        let a = makeWindow()
        let b = makeWindow()
        let agent = try focusedAgent(b)
        b.newTabForTesting()
        notify(agent, "Wants to run swift test")
        let row = try XCTUnwrap(waitingRow(a))

        a.sidebarForTesting.view.focusStop(.waitingElsewhere)
        XCTAssertTrue(a.window.firstResponder === row, "precondition")

        XCTAssertEqual(a.sidebarForTesting.focusedWorktreeRefusal, .agent, "a silent no-op is not an answer")
    }

    func test_askingAgainOnceYouAreLooking_clearsTheRowElsewhere() throws {
        let a = makeWindow()
        let b = makeWindow()
        let agent = try focusedAgent(b)
        WindowController.isPresent = { [weak b] window in window !== b?.window }

        notify(agent, "Wants to run swift test")
        XCTAssertEqual(waitingRow(a)?.textForTesting, "1 waiting in another window", "precondition")

        WindowController.isPresent = { _ in true }
        notify(agent, "Asks before the backfill")

        XCTAssertNil(waitingRow(a), "a notification you are looking at clears the wait, and that has to be published")
    }

    func test_theCountIsAgents_andBothHalvesOfTheCopyFollowIt() throws {
        let a = makeWindow()
        let b = makeWindow()
        let first = try focusedAgent(b)
        let second = try split(b)
        b.newTabForTesting()

        notify(first, "Wants to run swift test")
        XCTAssertEqual(waitingRow(a)?.textForTesting, "1 waiting in another window")

        notify(second, "Asks before the backfill")
        XCTAssertEqual(
            waitingRow(a)?.textForTesting, "2 waiting in another window",
            "two agents sharing one window is still another window")

        let c = makeWindow()
        let third = try focusedAgent(c)
        c.newTabForTesting()
        notify(third, "Wants to push")

        XCTAssertEqual(waitingRow(a)?.textForTesting, "3 waiting in other windows")
        XCTAssertEqual(waitingRow(b)?.textForTesting, "1 waiting in another window", "b sees only c")
    }

    func test_clickingTheRow_landsOnTheAgentThatHasWaitedLongest() throws {
        let a = makeWindow()
        let b = makeWindow()
        let first = try focusedAgent(b)
        b.newTabForTesting()
        let second = try focusedAgent(b)
        b.newTabForTesting()
        wireJump(from: a, to: [b])

        notify(first, "Wants to run swift test")
        notify(second, "Asks before the backfill")
        XCTAssertEqual(waitingRow(a)?.textForTesting, "2 waiting in another window", "precondition")
        XCTAssertNotEqual(b.focusedSurfaceIDForTesting, first.id, "precondition: b is showing a third tab")

        try click(try XCTUnwrap(waitingRow(a)))

        XCTAssertEqual(b.focusedSurfaceIDForTesting, first.id, "the one that has waited longest, not the last")
        XCTAssertEqual(
            waitingRow(a)?.textForTesting, "1 waiting in another window", "the later one still waits")
    }

    func test_whenTheWaitingPaneHasExited_itLandsOnThatTabInstead() throws {
        let a = makeWindow()
        let b = makeWindow()
        WindowController.isPresent = { [weak b] window in window !== b?.window }
        let agent = try focusedAgent(b)
        _ = try split(b)
        focus(agent, in: b)
        notify(agent, "Wants to run swift test")
        let spoke = try XCTUnwrap(b.activeTabIDForTesting)
        wireJump(from: a, to: [b])

        b.handle(.closePane)
        b.newTabForTesting()
        XCTAssertNotEqual(b.activeTabIDForTesting, spoke, "precondition: b is showing another tab")
        XCTAssertEqual(waitingRow(a)?.textForTesting, "1 waiting in another window", "a pane that exited still asks")

        try click(try XCTUnwrap(waitingRow(a)))

        XCTAssertEqual(b.activeTabIDForTesting, spoke)
        XCTAssertNil(waitingRow(a), "arriving on the tab answers it")
    }

    func test_theRowQueuesWithTheAgents_oldestWaitingFirst() throws {
        let a = makeWindow()
        let mine = try focusedAgent(a)
        let working = try split(a)
        let b = makeWindow()
        let theirs = try focusedAgent(b)
        b.newTabForTesting()
        progress(working, working: true)

        notify(theirs, "Wants to push")
        let row = try XCTUnwrap(waitingRow(a))
        XCTAssertEqual(
            section(a), [row, rows(a)[0]],
            "waiting outranks this window's working agent, so the row reads above it")

        notify(mine, "Wants to run swift test")
        XCTAssertEqual(
            section(a), [row, rows(a)[0], rows(a)[1]],
            "the other window asked first, so it keeps its place")
    }

    func test_aLocalAgentThatAskedFirst_readsAboveTheRow() throws {
        let a = makeWindow()
        let mine = try focusedAgent(a)
        _ = try split(a)
        let b = makeWindow()
        let theirs = try focusedAgent(b)
        b.newTabForTesting()

        notify(mine, "Wants to run swift test")
        notify(theirs, "Wants to push")

        let row = try XCTUnwrap(waitingRow(a))
        XCTAssertEqual(section(a), [rows(a)[0], row], "the oldest thing wanting you reads first, wherever it is")
    }

    func test_arrows_reachTheRowInItsPlace_andReturnJumps() throws {
        let a = makeWindow()
        let mine = try focusedAgent(a)
        let b = makeWindow()
        let theirs = try focusedAgent(b)
        b.newTabForTesting()
        wireJump(from: a, to: [b])
        progress(mine, working: true)
        notify(theirs, "Wants to run swift test")

        let workspaceRows = a.sidebarForTesting.view.rowsForTesting
        let row = try XCTUnwrap(waitingRow(a))
        XCTAssertEqual(section(a), [row, rows(a)[0]], "precondition: the row sorts above the working agent")

        a.sidebarForTesting.focusActiveRow()
        XCTAssertTrue(a.window.firstResponder === workspaceRows[0])
        a.window.sendEvent(arrow(125, in: a))
        XCTAssertTrue(a.window.firstResponder === row, "↓ reaches the row where it sits, not last")
        XCTAssertEqual(row.fillForTesting, Theme.current.chrome.selectionFill.cgColor)
        a.window.sendEvent(arrow(125, in: a))
        XCTAssertTrue(a.window.firstResponder === rows(a)[0], "↓ carries on into the agent below it")
        a.window.sendEvent(arrow(126, in: a))
        XCTAssertTrue(a.window.firstResponder === row, "↑ climbs back to it")

        a.window.sendEvent(returnKey(in: a))

        XCTAssertEqual(b.focusedSurfaceIDForTesting, theirs.id)
    }

    func test_hoveringAnAgent_showsTheWholeMessage_whileTheRowReadsItsFirstSentence() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)
        let body =
            "Wants to run swift test. It rebuilds GhosttyKit first, which takes a few minutes on a cold cache."
        notify(agent, body)
        let row = try XCTUnwrap(rows(c).first)

        XCTAssertEqual(row.summaryTextForTesting, "Wants to run swift test.", "the row stops at the sentence")
        XCTAssertEqual(row.frame.height, SidebarAgentRow.height, "the message does not grow the row")

        try hover(row, in: c)

        XCTAssertEqual(try presentedTooltip().labelForTesting, body)
        XCTAssertEqual(row.accessibilityLabel(), body, "a screen reader hears the whole message too")
    }

    // Drives the row's own render: a window-level render would settle hover first, which a non-key test window reads as a pointer that left.
    func test_aNewMessageWhileHovering_replacesTheTooltipUnderThePointer() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)
        notify(agent, "Wants to run swift test.")
        let row = try XCTUnwrap(rows(c).first)
        let first = try XCTUnwrap(row.itemForTesting)
        try hover(row, in: c)
        XCTAssertEqual(try presentedTooltip().labelForTesting, "Wants to run swift test.", "precondition")

        let body = "Wants to run bin/check, which rebuilds GhosttyKit first."
        row.render(
            SidebarAgentItem(
                id: first.id, state: first.state, summary: SidebarAgentItem.summaryLine(of: body),
                detail: first.detail, message: body))

        XCTAssertEqual(
            TooltipPresenter.shared.tooltipForTesting?.labelForTesting, body,
            "the tooltip under the pointer follows the row it belongs to")

        row.render(
            SidebarAgentItem(
                id: first.id, state: .working, summary: AttentionTone.working.summary, detail: first.detail,
                message: nil))

        XCTAssertEqual(
            TooltipPresenter.shared.tooltipForTesting?.labelForTesting, "Jump to agent",
            "a progress tick clearing the message takes the tooltip back with it")
    }

    func test_hoveringAnAgentWithNoMessage_stillSaysWhatClickingDoes() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)
        notify(agent, "Wants to run swift test. It rebuilds GhosttyKit first.")
        focus(agent, in: c)
        c.answerTypedAgent()
        let row = try XCTUnwrap(rows(c).first)
        XCTAssertEqual(row.summaryTextForTesting, "Idle", "precondition: an answered agent shows a state word")

        try hover(row, in: c)

        XCTAssertEqual(try presentedTooltip().labelForTesting, "Jump to agent")
    }

    func test_aHoveredMessage_wrapsInsideTheTooltipColumn() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)
        let line = ChromeTooltip(label: "One line", shortcut: nil).fittingSize.height
        let bodies = [
            String(repeating: "supercalifragilistic", count: 6),
            "Wants to run swift test. It rebuilds GhosttyKit first, which takes a few minutes on a cold cache.",
        ]

        for body in bodies {
            notify(agent, body)
            let row = try XCTUnwrap(rows(c).first)
            try hover(row, in: c)
            let tooltip = try presentedTooltip()
            let size = tooltip.fittingSize

            XCTAssertLessThanOrEqual(
                size.width, ChromeTooltip.paragraphMaxWidth + 18,
                "runs \(Int(size.width))pt past the \(Int(ChromeTooltip.paragraphMaxWidth))pt column: \(body)")
            XCTAssertGreaterThan(size.height, line, "the whole message needs more than one line: \(body)")
            try unhover(row, in: c)
        }
    }
}
