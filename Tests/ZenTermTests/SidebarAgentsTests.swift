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

    private func notify(_ agent: Agent, _ body: String, title: String = "") {
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

    private func items(_ c: WindowController) -> [SidebarAgentItem] {
        rows(c).compactMap(\.itemForTesting)
    }

    private func focus(_ agent: Agent, in c: WindowController) {
        while c.focusedSurfaceIDForTesting != agent.id { c.handle(.nextPane) }
    }

    private func click(_ row: SidebarAgentRow) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        row.mouseDown(with: event)
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
        XCTAssertEqual(items(c).map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(items(c).map(\.state), [.waiting, .done, .idle])
        XCTAssertEqual(items(c).last?.summary, "Idle", "an answered question does not linger")

        progress(third, working: true)
        XCTAssertEqual(items(c).map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(items(c).map(\.state), [.waiting, .working, .idle])
    }

    func test_anAgentWaitingInAnUnfocusedSplit_staysWaitingUntilThatPaneIsFocused() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        _ = try split(c)

        notify(first, "Wants to run swift test")

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "the tab number keeps using tab activeness")
        XCTAssertEqual(items(c).map(\.state), [.waiting])

        _ = try split(c)
        XCTAssertEqual(items(c).map(\.state), [.waiting], "focusing another pane does not answer it")

        focus(first, in: c)
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

    func test_aSignallingShell_joinsAsAnAgent_namedBySignalWhenItCarriesOne() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        let second = try split(c)
        _ = try split(c)

        notify(first, "Needs input")
        notify(second, "Needs input", title: "Claude Code")

        XCTAssertEqual(Set(items(c).map(\.detail)), ["Workspace 1 · agent", "Workspace 1 · Claude Code"])
    }

    func test_anAgentThatWorksBeforeItAsks_takesTheNameItsNotificationCarries() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)

        progress(agent, working: true)
        XCTAssertEqual(items(c).map(\.detail), ["Workspace 1 · agent"], "precondition: joined unnamed")
        notify(agent, "Needs input", title: "Claude Code")

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

    func test_anAgentExitingNonZero_staysUntilItsPaneIsFocused() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        let second = try split(c)
        notify(first, "Wants to run swift test")
        focus(first, in: c)
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
        XCTAssertEqual(items(c).map(\.state), [.idle])
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
        float.delegate?.surface(float, didPostNotification: TerminalNotification(title: "", body: "Needs input"))
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

}
