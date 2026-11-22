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
        var config = GeneralConfig.builtInWithStickyCards
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
        TooltipPresenter.shared.dismiss()
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
            title: title, path: folder, tabs: [Workspace.Tab(right: right)], env: [:])
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

    private func retitle(_ agent: Agent, _ title: String) {
        agent.surface.delegate?.surface(agent.surface, titleDidChange: title)
        drainMainQueue()
    }

    private func report(_ state: TerminalProgramStatus.State, title: String? = nil, from agent: Agent) {
        agent.surface.delegate?.surface(
            agent.surface, programStatusDidChange: TerminalProgramStatus(state: state, title: title))
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
        TooltipPresenter.shared.dismiss()
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

    private func finishATurn(_ agent: Agent) {
        progress(agent, working: true)
        progress(agent, working: false)
    }

    private func tabChips(_ c: WindowController) -> [TerminalTabChip] {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return descendants(c.containerForTesting).compactMap { $0 as? TabBarView }.first?.chipsForTesting ?? []
    }

    private func row(of agent: Agent, in c: WindowController) throws -> SidebarAgentRow {
        try XCTUnwrap(rows(c).first { $0.itemForTesting?.id == agent.id })
    }

    private func indicators(_ c: WindowController) -> [TabChip.Indicator?] {
        tabChips(c).map { chip in
            if chip.isSpinningForTesting { return .spinner }
            return chip.isDotVisibleForTesting ? chip.dotStateForTesting.map { .dot($0) } : nil
        }
    }

    func test_anAgentRow_showsBlockedDoneWorkingAndIdle() throws {
        let c = makeWindow()
        let finished = try focusedAgent(c)
        let asking = try split(c)
        let working = try split(c)
        let idle = try split(c)
        for agent in [finished, working, idle] { c.identifyAgentForTesting(agent.id, name: "claude") }
        WindowController.isPresent = { _ in false }

        finishATurn(finished)
        notify(asking, "Wants to run swift test")
        progress(working, working: true)

        let chrome = Theme.current.chrome
        let blockedRow = try row(of: asking, in: c)
        XCTAssertEqual(blockedRow.dotForTesting.state, .blocked)
        XCTAssertEqual(blockedRow.dotForTesting.colorForTesting, chrome.blocked.nsColor.cgColor)
        XCTAssertFalse(blockedRow.isSpinningForTesting)

        let doneRow = try row(of: finished, in: c)
        XCTAssertEqual(doneRow.dotForTesting.state, .done)
        XCTAssertEqual(doneRow.dotForTesting.colorForTesting, chrome.done.nsColor.cgColor)
        XCTAssertFalse(doneRow.isSpinningForTesting)

        let workingRow = try row(of: working, in: c)
        XCTAssertNil(workingRow.dotForTesting.state, "the spinner says working, not a dot")
        XCTAssertTrue(workingRow.isSpinningForTesting)

        let idleRow = try row(of: idle, in: c)
        XCTAssertEqual(idleRow.dotForTesting.state, .idle)
        XCTAssertEqual(idleRow.dotForTesting.colorForTesting, chrome.ink(.muted).cgColor)
        XCTAssertFalse(idleRow.isSpinningForTesting)
    }

    func test_aTab_showsWhatItsAgentRowShows() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        c.identifyAgentForTesting(agent.id, name: "claude")
        WindowController.isPresent = { _ in false }
        c.newTabForTesting()
        let asking = try focusedAgent(c)

        XCTAssertEqual(c.agentStateForTesting(agent.id), .idle, "precondition")
        XCTAssertEqual(indicators(c), [nil, nil], "an idle agent shows nothing, and neither does a tab with none")

        progress(agent, working: true)
        XCTAssertEqual(c.agentStateForTesting(agent.id), .working, "precondition")
        XCTAssertEqual(indicators(c), [.spinner, nil])

        progress(agent, working: false)
        XCTAssertEqual(c.agentStateForTesting(agent.id), .done, "precondition")
        XCTAssertEqual(indicators(c), [.dot(.done), nil])
        XCTAssertEqual(
            try XCTUnwrap(tabChips(c).first).dotColorForTesting, Theme.current.chrome.done.nsColor.cgColor)

        notify(asking, "Wants to run swift test")
        XCTAssertEqual(c.agentStateForTesting(asking.id), .blocked, "precondition")
        XCTAssertEqual(indicators(c), [.dot(.done), .dot(.blocked)])
        XCTAssertEqual(
            try XCTUnwrap(tabChips(c).last).dotColorForTesting, Theme.current.chrome.blocked.nsColor.cgColor)

        WindowController.isPresent = { _ in true }
        c.answerTypedAgent()
        XCTAssertEqual(c.agentStateForTesting(asking.id), .idle, "precondition: answered")
        XCTAssertEqual(indicators(c), [.dot(.done), nil], "the tab clears when its row does")

        c.selectTabForTesting(index: 0)
        XCTAssertEqual(c.agentStateForTesting(agent.id), .idle, "precondition: seen")
        XCTAssertEqual(indicators(c), [nil, nil])
    }

    func test_aTabWithSeveralAgents_showsBlockedOverDoneOverWorking() throws {
        let c = makeWindow()
        let finished = try focusedAgent(c)
        let working = try split(c)
        let asking = try split(c)
        for agent in [finished, working] { c.identifyAgentForTesting(agent.id, name: "claude") }
        WindowController.isPresent = { _ in false }

        progress(working, working: true)
        XCTAssertEqual(indicators(c), [.spinner])

        finishATurn(finished)
        XCTAssertEqual(indicators(c), [.dot(.done)], "done over working")

        notify(asking, "Wants to run swift test")
        XCTAssertEqual(indicators(c), [.dot(.blocked)], "blocked over done and working")

        WindowController.isPresent = { _ in true }
        c.answerTypedAgent()
        XCTAssertEqual(c.agentStateForTesting(asking.id), .idle, "precondition: answered")
        XCTAssertEqual(indicators(c), [.dot(.done)])
    }

    func test_aCommandFinishingUnseen_showsNoDotOnItsTab() throws {
        let c = makeWindow()
        WindowController.isPresent = { _ in false }

        c.notifyCommandFinishedForTesting(tabIndex: 0, result: TerminalCommandResult(exitCode: 0, duration: 30))
        drainMainQueue()

        XCTAssertEqual(c.attentionStateForTesting(tabIndex: 0), .completed, "precondition: the finish latched")
        XCTAssertEqual(tabChips(c).map(\.dotStateForTesting), [nil])
        XCTAssertFalse(try XCTUnwrap(tabChips(c).first).isDotVisibleForTesting)
    }

    func test_noAgents_hidesTheSection() {
        let c = makeWindow()

        XCTAssertTrue(c.sidebarForTesting.view.agentsAreHiddenForTesting)
        XCTAssertTrue(rows(c).isEmpty)
    }

    func test_rowsSortWaitingThenWorkingThenIdle_asStatesChange() throws {
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
        XCTAssertEqual(items(c).map(\.state), [.blocked, .working, .idle])
        XCTAssertEqual(
            items(c).map(\.summary), ["pi", AgentRoster.unnamed, AgentRoster.unnamed])
        XCTAssertEqual(items(c).first?.message, "Wants to run swift test")
        XCTAssertFalse(c.sidebarForTesting.view.agentsAreHiddenForTesting)

        notify(second, "Asks before the backfill")
        XCTAssertEqual(items(c).map(\.id), [first.id, second.id, third.id], "the longest waiting reads first")

        focus(first, in: c)
        c.answerTypedAgent()
        XCTAssertEqual(items(c).map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(items(c).map(\.state), [.blocked, .idle, .idle])
        XCTAssertEqual(items(c)[1].summary, "pi", "an answered question does not linger")

        progress(third, working: true)
        XCTAssertEqual(items(c).map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(items(c).map(\.state), [.blocked, .working, .idle])
    }

    func test_anAgentWaitingInAnUnfocusedSplit_staysWaitingUntilItIsAnswered() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        _ = try split(c)

        notify(first, "Wants to run swift test")

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "the tab number keeps using tab activeness")
        XCTAssertEqual(items(c).map(\.state), [.blocked])

        _ = try split(c)
        XCTAssertEqual(items(c).map(\.state), [.blocked], "focusing another pane does not answer it")

        focus(first, in: c)
        XCTAssertEqual(items(c).map(\.state), [.blocked], "focusing it back is not answering it")

        c.answerTypedAgent()
        XCTAssertEqual(items(c).map(\.state), [.idle])
        XCTAssertEqual(
            rows(c).first?.fillForTesting, NSColor.clear.cgColor, "only the workspace row reads as active")
    }

    func test_aLaunchedAgent_isListedIdleFromLaunch_andOtherProgramsAreNot() throws {
        let c = makeWindow()

        c.openWorkspaceForTesting(recipe("zen-review", right: "claude --resume"))
        c.openWorkspaceForTesting(recipe("notes", right: "vim"))

        XCTAssertEqual(items(c).map(\.summary), ["claude"])
        XCTAssertEqual(items(c).map(\.detail), ["zen-review"])
        XCTAssertEqual(items(c).map(\.state), [.idle])
    }

    func test_anAgentsReportedTitle_winsOverItsPaneTitle_untilTheReportClears() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        c.identifyAgentForTesting(agent.id, name: "claude")
        retitle(agent, "✳ Fix the sidebar")

        report(.working, title: "Fix the login bug", from: agent)
        XCTAssertEqual(rows(c).first?.summaryTextForTesting, "Fix the login bug", "the agent's own title wins")
        retitle(agent, "⠋ Something else")
        XCTAssertEqual(rows(c).first?.summaryTextForTesting, "Fix the login bug", "a pane title never covers it")

        report(.working, from: agent)
        XCTAssertEqual(rows(c).first?.summaryTextForTesting, "Something else", "a report with no title falls through")

        report(.working, title: "Fix the login bug", from: agent)
        agent.surface.delegate?.surface(agent.surface, programStatusDidChange: nil)
        drainMainQueue()
        XCTAssertEqual(rows(c).first?.summaryTextForTesting, "Something else", "a cleared report takes its title")
    }

    func test_anAgentRowsTitle_isItsPaneTitle_elseItsName_evenWhileItAsks() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        c.identifyAgentForTesting(agent.id, name: "claude")
        XCTAssertEqual(c.agentRowForTesting(agent.id)?.summary, "claude", "no title falls back to the name")
        XCTAssertEqual(c.agentRowForTesting(agent.id)?.detail, "Workspace 1", "the second line is the place alone")

        retitle(agent, "✳ Fix the sidebar")
        XCTAssertEqual(c.agentStateForTesting(agent.id), .idle, "precondition: the title moved no state")
        XCTAssertEqual(rows(c).first?.summaryTextForTesting, "Fix the sidebar", "a new pane title re-renders the row")
        XCTAssertEqual(rows(c).first?.accessibilityValue() as? String, "Idle, Workspace 1")

        retitle(agent, "✳ Review the diff")
        XCTAssertEqual(rows(c).first?.summaryTextForTesting, "Review the diff", "and so does the next")

        notify(agent, "Wants to run swift test", title: "Claude Code")
        let row = try XCTUnwrap(rows(c).first)
        XCTAssertEqual(row.summaryTextForTesting, "Review the diff", "the dot says it asks; the title stays")
        XCTAssertEqual(
            row.accessibilityLabel(), "Review the diff, Wants to run swift test",
            "VoiceOver names the row before its ask, or two asking rows sound alike")
        XCTAssertEqual(row.accessibilityValue() as? String, "Waiting, Workspace 1")
        try hover(row, in: c)
        XCTAssertEqual(try presentedTooltip().labelForTesting, "Wants to run swift test", "the tooltip keeps the ask")
    }

    func test_anAgentRowsTitle_dropsTheAgentsStatusGlyph_andItsChurnRendersNothing() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        c.identifyAgentForTesting(agent.id, name: "claude")

        retitle(agent, "✳ Fix the sidebar")
        XCTAssertEqual(rows(c).first?.summaryTextForTesting, "Fix the sidebar")

        let row = try XCTUnwrap(rows(c).first)
        let renders = row.rendersForTesting
        for frame in ["◐ Fix the sidebar", "◑  Fix the sidebar", "· Fix the sidebar"] { retitle(agent, frame) }
        XCTAssertEqual(row.summaryTextForTesting, "Fix the sidebar")
        XCTAssertEqual(row.rendersForTesting, renders, "a spinner frame is not a new title")

        for (title, shown) in [
            ("✳ 2 files to review", "2 files to review"), ("✳ #42 fix login", "#42 fix login"),
            ("✳ [WIP] refactor", "[WIP] refactor"),
        ] {
            retitle(agent, title)
            XCTAssertEqual(rows(c).first?.summaryTextForTesting, shown, "only the glyph is the agent's prefix")
        }
    }

    func test_aCodexRowsTitle_isItsTask_neverItsPromptOrItsFolder() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)
        retitle(agent, AgentTitleFixtures.codexLaunch)
        XCTAssertEqual(c.agentNameForTesting(agent.id), "codex", "precondition: its launch title names it")
        XCTAssertEqual(items(c).first?.summary, "codex")

        for title in AgentTitleFixtures.codexWorking + [
            AgentTitleFixtures.codexBlockedOn, AgentTitleFixtures.codexBlockedOff, AgentTitleFixtures.codexIdle,
        ] {
            retitle(agent, title)
            XCTAssertEqual(items(c).first?.summary, "Create test.txt", "\(title) titles the row by its task")
        }
        retitle(agent, AgentTitleFixtures.codexRenaming)
        XCTAssertEqual(items(c).first?.summary, "renaming...")
        retitle(agent, AgentTitleFixtures.codexBareIdle)
        XCTAssertEqual(items(c).first?.summary, "codex", "a bare folder is not a task")
    }

    func test_anAgentThatDoesNotTitleItsPane_showsItsName_overTheShellsTitle() throws {
        var config = GeneralConfig.current
        config.agents = ["gemini"]
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        c.openWorkspaceForTesting(recipe("zen-review", right: "gemini --yolo"))
        let agent = try XCTUnwrap(rows(c).first?.itemForTesting)
        let surface = try XCTUnwrap(spawned.last)

        surface.delegate?.surface(surface, titleDidChange: "gemini --yolo")
        drainMainQueue()

        XCTAssertEqual(c.agentRowForTesting(agent.id)?.summary, "gemini")

        surface.delegate?.surface(
            surface, programStatusDidChange: TerminalProgramStatus(state: .working, title: "Fix the login bug"))
        drainMainQueue()
        XCTAssertEqual(c.agentRowForTesting(agent.id)?.summary, "Fix the login bug", "its own report still titles it")
    }

    func test_anExitedAgentKeptForItsResult_dropsItsPaneTitle() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)
        c.identifyAgentForTesting(agent.id, name: "claude")
        retitle(agent, "✳ Fix the sidebar")
        agent.surface.isBusy = true
        c.trackAgentExitsForTesting()

        agent.surface.delegate?.surface(
            agent.surface, commandDidFinish: TerminalCommandResult(exitCode: 1, duration: 3))
        drainMainQueue()
        agent.surface.isBusy = false
        c.trackAgentExitsForTesting()
        retitle(agent, "~/Dev/zen-term")

        XCTAssertEqual(items(c).map(\.state), [.blocked], "precondition: the crash waits on you")
        XCTAssertEqual(items(c).first?.summary, "claude", "the shell's title is not the agent's")
    }

    func test_anUnnamedAgentWithNoTitle_readsAsAnAgent_neverAsItsState() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)

        progress(agent, working: true)

        XCTAssertEqual(items(c).map(\.state), [.working], "precondition")
        XCTAssertEqual(items(c).map(\.summary), [AgentRoster.unnamed])
    }

    func test_noStateChange_putsAStateWordOfOursInAnAgentRowsTitle() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        let other = try split(c)
        c.identifyAgentForTesting(agent.id, name: "claude")
        WindowController.isPresent = { _ in false }
        let ours = Set([AttentionTone.blocked, .done, .working, .idle].map { $0.accessibilityName.lowercased() })
        var seen: [AttentionTone] = []
        func expectNoStateWord(_ step: String, on watched: Agent? = nil) {
            let id = (watched ?? agent).id
            guard let row = rows(c).first(where: { $0.itemForTesting?.id == id }) else {
                return XCTFail("precondition: \(step) left no row")
            }
            row.itemForTesting.map { seen.append($0.state) }
            let words = Set(row.summaryTextForTesting.lowercased().split { !$0.isLetter }.map(String.init))
            XCTAssertTrue(
                words.isDisjoint(with: ours), "\(step) titled the row \"\(row.summaryTextForTesting)\"")
        }

        progress(agent, working: true)
        expectNoStateWord("working")
        progress(agent, working: false)
        expectNoStateWord("a finished turn")
        notify(agent, "Wants to run swift test", title: "")
        expectNoStateWord("an ask")
        focus(agent, in: c)
        c.answerTypedAgent()
        expectNoStateWord("an answer")
        focus(other, in: c)
        for state: TerminalProgramStatus.State in [.working, .blocked(.permission), .done, .failed, .idle] {
            report(state, from: agent)
            expectNoStateWord("a reported \(state)")
        }
        retitle(agent, "◐")
        expectNoStateWord("a glyph-only pane title")
        XCTAssertEqual(Set(seen), [.blocked, .done, .working, .idle], "precondition: every state was reached")

        c.identifyAgentForTesting(other.id, name: "codex")
        for title in [
            AgentTitleFixtures.codexBlockedOn, AgentTitleFixtures.codexWorking[0], AgentTitleFixtures.codexIdle,
            AgentTitleFixtures.codexBareIdle, AgentTitleFixtures.codexRenaming,
        ] {
            retitle(other, title)
            expectNoStateWord("codex's \(title)", on: other)
        }
    }

    func test_aListedProgram_joinsOnLaunch_andByItsNotificationTitle() throws {
        var config = GeneralConfig.current
        config.agents = ["gemini"]
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        c.openWorkspaceForTesting(recipe("zen-review", right: "gemini --yolo"))
        XCTAssertEqual(items(c).map(\.summary), ["gemini"])

        let shell = try split(c)
        notify(shell, "Waiting for input", title: "gemini")

        XCTAssertEqual(items(c).count, 2)
    }

    func test_aShellsNotification_joinsNothing_whileOneNamingAnAgent_joinsUnderThatName() throws {
        let c = makeWindow()
        let shell = try focusedAgent(c)
        let second = try split(c)
        _ = try split(c)

        notify(shell, "Build finished", title: "")
        notify(second, "Claude needs your permission", title: "Claude Code")

        XCTAssertEqual(items(c).map(\.id), [second.id])
    }

    func test_anAgentThatWorksBeforeItAsks_takesTheNameItsNotificationCarries() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)

        progress(agent, working: true)
        XCTAssertEqual(items(c).map(\.summary), [AgentRoster.unnamed], "precondition: joined unnamed")
        notify(agent, "Claude needs your permission", title: "Claude Code")

        XCTAssertEqual(c.agentNameForTesting(agent.id), "Claude Code")
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
        XCTAssertEqual(items(c).count, 1, "the exit's own result gets one poll to land first")
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

        XCTAssertEqual(items(c).map(\.state), [.blocked], "a crash waits on you")
        XCTAssertEqual(items(c).first?.message, WindowController.commandResultMessage(result))

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
        c.trackAgentExitsForTesting()

        XCTAssertTrue(items(c).isEmpty)
        XCTAssertEqual(c.agentStateForTesting(agent.id), .idle)
    }

    func test_anAgentThatAskedThenExitsNonZero_readsExited() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        _ = try split(c)
        notify(first, "Wants to run swift test")
        XCTAssertEqual(items(c).map(\.state), [.blocked], "precondition")

        let result = TerminalCommandResult(exitCode: 1, duration: 3)
        first.surface.delegate?.surface(first.surface, commandDidFinish: result)
        drainMainQueue()

        XCTAssertEqual(items(c).map(\.state), [.blocked])
        XCTAssertEqual(items(c).first?.message, WindowController.commandResultMessage(result))
    }

    func test_anAgentStoppedWithCtrlC_doesNotReadAsFailed() throws {
        let c = makeWindow()
        let first = try focusedAgent(c)
        _ = try split(c)
        notify(first, "Wants to run swift test")
        XCTAssertEqual(items(c).map(\.state), [.blocked], "precondition")

        let result = TerminalCommandResult(exitCode: 130, duration: 3)
        first.surface.delegate?.surface(first.surface, commandDidFinish: result)
        drainMainQueue()

        XCTAssertTrue(items(c).isEmpty, "Ctrl-C is a deliberate stop, not a crash")
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
    private static let waitingElsewhereMessage = "An agent is waiting in another window."

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
            items(c).filter { $0.state.isWaiting }.map(\.id), [first.id, second.id],
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
        let queue = items(c).filter { $0.state.isWaiting }.map(\.id)
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
        AttentionCenter.shared.update(windowID: other, blockedCount: 1)
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
            items(c).map(\.state), [.blocked], "the jump takes you to the prompt, it does not answer it")
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
                id: "pi", order: 0, title: "pi", icon: ToolFloatParser.defaultIcon,
                command: "pi", dir: nil, widthFraction: 0.85, heightFraction: 0.85,
                requiresGitRepo: false, persist: .window,
                toggle: Chord(command: true, shift: true, key: "b"))
        ]
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        c.handle(.toggleToolFloat("pi"))
        let float = try XCTUnwrap(spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "pi"] })
        c.handle(.toggleToolFloat("pi"))
        XCTAssertNil(c.floatsForTesting.activeID, "precondition: the float is hidden")
        float.delegate?.surface(float, didPostNotification: TerminalNotification(title: "pi", body: "Needs input"))
        drainMainQueue()

        try click(try XCTUnwrap(rows(c).first))

        XCTAssertEqual(c.floatsForTesting.activeID, "pi")
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
        XCTAssertEqual(agentRows[0].fillForTesting, NSColor.clear.cgColor)
        XCTAssertEqual(agentRows[0].ringForTesting, Theme.current.chrome.focusRing.cgColor)
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

    func test_aWorkspaceRow_showsNoAgentState_whateverItsAgentsDo() throws {
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        c.openWorkspaceForTesting(recipe("zen-review", right: nil))
        let finished = try focusedAgent(c)
        let asking = try split(c)
        c.identifyAgentForTesting(finished.id, name: "claude")
        c.activateWorkspaceForTesting(home)
        WindowController.isPresent = { _ in false }
        let rows = c.sidebarForTesting.view.rowsForTesting
        func shownStates() -> [[StateDot.State]] {
            rows.map { row in descendants(of: row).compactMap { ($0 as? StateDot)?.state } }
        }

        progress(finished, working: true)
        XCTAssertEqual(c.agentStateForTesting(finished.id), .working, "precondition")
        XCTAssertEqual(shownStates(), [[], []])

        progress(finished, working: false)
        XCTAssertEqual(c.agentStateForTesting(finished.id), .done, "precondition")
        XCTAssertEqual(shownStates(), [[], []])

        notify(asking, "Wants to run swift test")
        XCTAssertEqual(c.agentStateForTesting(asking.id), .blocked, "precondition")
        XCTAssertEqual(shownStates(), [[], []])
        XCTAssertNil(rows[1].accessibilityValue(), "and says none")
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

    func test_anAgentAskingInAWindowYouAreNotIn_waits_thoughItsPaneIsOnScreen() throws {
        let a = makeWindow()
        let b = makeWindow()
        let agent = try focusedAgent(b)
        WindowController.isPresent = { [weak b] window in window !== b?.window }

        notify(agent, "Wants to run swift test")

        XCTAssertEqual(
            AttentionCenter.shared.blockedCount(excluding: a.windowID), 1,
            "a pane you can see from another window has not been seen")
        XCTAssertEqual(b.attentionStateForTesting(tab: try XCTUnwrap(b.activeTabIDForTesting)), .waiting)
    }

    func test_hoveringAnAgent_showsTheWholeMessage_whileTheRowKeepsItsTitle() throws {
        let c = makeWindow()
        let agent = try focusedAgent(c)
        _ = try split(c)
        let body =
            "Wants to run swift test. It rebuilds GhosttyKit first, which takes a few minutes on a cold cache."
        notify(agent, body)
        let row = try XCTUnwrap(rows(c).first)

        XCTAssertEqual(row.summaryTextForTesting, "pi", "the message never replaces the title")
        XCTAssertEqual(row.frame.height, SidebarAgentRow.height, "the message does not grow the row")

        try hover(row, in: c)

        XCTAssertEqual(try presentedTooltip().labelForTesting, body)
        XCTAssertEqual(row.accessibilityLabel(), "pi, \(body)", "a screen reader hears the whole message too")
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
                id: first.id, state: first.state, summary: first.summary,
                detail: first.detail, message: body))

        XCTAssertEqual(
            TooltipPresenter.shared.tooltipForTesting?.labelForTesting, body,
            "the tooltip under the pointer follows the row it belongs to")

        row.render(
            SidebarAgentItem(
                id: first.id, state: .working, summary: "claude", detail: first.detail,
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
        XCTAssertEqual(row.summaryTextForTesting, "pi", "precondition: an answered agent shows its name")

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
                size.width, ChromeTooltip.paragraphMaxWidth + 2 * ChromeMetrics.Spacing.controlInset,
                "runs \(Int(size.width))pt past the \(Int(ChromeTooltip.paragraphMaxWidth))pt column: \(body)")
            XCTAssertGreaterThan(size.height, line, "the whole message needs more than one line: \(body)")
            try unhover(row, in: c)
        }
    }
}
