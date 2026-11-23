import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class AgentNestingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private let jobs = ProgramJobs()

    private struct Pane {
        let token: Int
        let id: SurfaceID
        let surface: RecordingSurface
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
        GeneralConfig.setCurrentForTesting(.builtIn)
        WindowController.isPresent = { _ in true }
    }

    override func tearDownWithError() throws {
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        spawned = []
        jobs.stopAll()
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        TooltipPresenter.shared.dismiss()
        SidebarController.resetLastChoiceForTesting()
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            initialCWD: FileManager.default.temporaryDirectory)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func responder(_ c: WindowController) -> ControlResponder {
        ControlResponder(windows: { [c] in [c] }, keyWindow: { [c] in c })
    }

    private func pane(_ token: Int, in c: WindowController) throws -> Pane {
        let id = try XCTUnwrap(c.pane(token: token)?.pane.surfaceID)
        let surface = try XCTUnwrap(
            spawned.first { $0.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init) == token })
        return Pane(token: token, id: id, surface: surface)
    }

    private func rootAgent(_ c: WindowController) throws -> Pane {
        let token = try XCTUnwrap(spawned.first?.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
        let root = try pane(token, in: c)
        report(.working, from: root)
        return root
    }

    private func run(
        _ cmd: String, from parent: Pane?, keep: Bool = false, outlivesParent: Bool = false,
        split: PaneDirection? = nil, in c: WindowController
    ) throws -> Pane {
        var reply: ControlReply?
        responder(c).respond(
            to: ControlRequest(
                id: 1, cmd: .paneRun,
                args: ControlArgs(
                    cmd: cmd, split: split, keep: keep ? true : nil, outliveParent: outlivesParent ? true : nil),
                caller: parent.map { ControlCaller(pane: $0.token) })
        ) { reply = $0 }
        let result = try XCTUnwrap(try XCTUnwrap(reply).get() as? PaneRunResult)
        drainMainQueue()
        return try pane(result.pane, in: c)
    }

    private func report(_ state: TerminalProgramStatus.State, from pane: Pane) {
        pane.surface.delegate?.surface(
            pane.surface, programStatusDidChange: TerminalProgramStatus(state: state, app: "claude"))
        drainMainQueue()
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func rows(_ c: WindowController) -> [SidebarAgentRow] {
        c.sidebarForTesting.view.agentRowsForTesting
    }

    private func items(_ c: WindowController) -> [SidebarAgentItem] {
        rows(c).compactMap(\.itemForTesting)
    }

    private func row(of pane: Pane, in c: WindowController) throws -> SidebarAgentRow {
        try XCTUnwrap(rows(c).first { $0.itemForTesting?.id == pane.id }, "no row for pane \(pane.token)")
    }

    private func click(_ row: NSView) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        row.mouseDown(with: event)
    }

    func test_aChildPaneListsNestedUnderTheAgentThatStartedIt() throws {
        let c = makeWindow()
        let root = try rootAgent(c)

        let helper = try run("claude", from: root, in: c)
        let process = try run("htop", from: root, in: c)

        XCTAssertEqual(items(c).map(\.id), [root.id, helper.id, process.id])
        XCTAssertEqual(items(c).map(\.role), [.agent, .helper, .process(nested: true)])
        let parentRow = try row(of: root, in: c)
        XCTAssertFalse(parentRow.isNestedForTesting)
        XCTAssertEqual(parentRow.leadingProcessForTesting?.name, "Claude Code", "a top-level agent leads with its chip")
        XCTAssertNotNil(parentRow.processBadgeForTesting, "the row draws no chip for its agent")
        XCTAssertEqual(parentRow.frame.height, SidebarAgentRow.height)
        let helperRow = try row(of: helper, in: c)
        XCTAssertTrue(helperRow.isNestedForTesting)
        XCTAssertEqual(helperRow.leadingProcessForTesting?.name, "Claude Code", "a helper leads with its agent's chip")
        XCTAssertEqual(helperRow.processBadgeForTesting?.process?.name, "Claude Code")
        XCTAssertTrue(helperRow.showsStateForTesting, "a helper agent shows its own state")
        XCTAssertEqual(helperRow.frame.height, ChromeMetrics.Height.control)
        let processRow = try row(of: process, in: c)
        XCTAssertTrue(processRow.isNestedForTesting)
        XCTAssertEqual(processRow.processBadgeForTesting?.process, .shell, "a process at its prompt shows the shell")
        XCTAssertFalse(processRow.showsStateForTesting, "a process row shows a state")
    }

    func test_aHelperLeadsWithItsAgentsMark_elseTheRobot() throws {
        let c = makeWindow()
        let root = try rootAgent(c)

        let codex = try run("codex", from: root, in: c)
        let unmarked = try run("aider", from: root, in: c)
        unmarked.surface.delegate?.surface(
            unmarked.surface, programStatusDidChange: TerminalProgramStatus(state: .working, app: "aider"))
        drainMainQueue()

        XCTAssertEqual(try row(of: codex, in: c).leadingProcessForTesting?.name, "Codex")
        XCTAssertEqual(try row(of: unmarked, in: c).itemForTesting?.role, .helper, "precondition: aider is an agent")
        XCTAssertEqual(try row(of: unmarked, in: c).leadingProcessForTesting, .unknownAgent)
        let promoted = try run("aider", from: nil, in: c)
        promoted.surface.delegate?.surface(
            promoted.surface, programStatusDidChange: TerminalProgramStatus(state: .working, app: "aider"))
        drainMainQueue()
        XCTAssertEqual(try row(of: promoted, in: c).itemForTesting?.role, .agent, "precondition")
        XCTAssertEqual(
            try row(of: promoted, in: c).leadingProcessForTesting, .unknownAgent,
            "an agent with no mark leads with the robot, never a blank column")
    }

    func test_aProcessRowsChip_followsItsProgram_inAPaneNoTabChipShows() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let process = try run("htop", from: root, split: .right, in: c)
        let place = try XCTUnwrap(c.pane(token: root.token))
        c.focus(root.id, in: place.tab)
        XCTAssertEqual(try XCTUnwrap(c.pane(token: process.token)).tab, place.tab, "precondition: one tab")
        XCTAssertEqual(try row(of: process, in: c).processBadgeForTesting?.process, .shell, "precondition")

        process.surface.foregroundProcessGroupID = try jobs.start(named: "htop")
        c.pollTitlesForTesting()

        XCTAssertEqual(try row(of: process, in: c).processBadgeForTesting?.process?.name, "htop")

        process.surface.foregroundProcessGroupID = 1
        c.pollTitlesForTesting()
        XCTAssertEqual(
            try row(of: process, in: c).processBadgeForTesting?.process, .unknown,
            "a program whose arguments cannot be read is not the resting shell")
    }

    func test_theDetailLine_namesTheWorkspace_andOnlyAnUnmarkedAgentAddsItsName() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let unmarked = try run("aider", from: nil, in: c)
        unmarked.surface.delegate?.surface(
            unmarked.surface, programStatusDidChange: TerminalProgramStatus(state: .working, app: "aider"))
        drainMainQueue()

        func lines(of row: NSView) -> [String] {
            func labels(_ view: NSView) -> [NSTextField] {
                view.subviews.flatMap { (($0 as? NSTextField).map { [$0] } ?? []) + labels($0) }
            }
            return labels(row).map(\.stringValue)
        }
        let workspace = try XCTUnwrap(c.workspaceNamesForTesting.first)
        let title = try row(of: root, in: c).summaryTextForTesting
        XCTAssertEqual(
            lines(of: try row(of: root, in: c)).filter { $0 != title }, [workspace],
            "a marked agent's chip already names it, so its detail is the workspace alone")
        XCTAssertTrue(lines(of: try row(of: unmarked, in: c)).contains("aider · \(workspace)"))
    }

    func test_everyAgentMarkDrawsInItsRow_neverAnSFSymbolOfTheSameName() {
        for agent in ["claude", "codex", "gemini", "copilot", "opencode", "pi", "ollama", "aider"] {
            let mark = ProcessIcon.forAgent(agent).mark
            XCTAssertNil(
                NSImage(systemSymbolName: mark, accessibilityDescription: nil),
                "\(mark) names an SF Symbol, which the row would draw in its place")
            XCTAssertNotNil(IconCatalog.image(mark), "\(agent)'s mark does not draw")
        }
    }

    func test_aFamilySortsByItsMostUrgentMember_whileEachDotSpeaksForItsOwnRow() throws {
        let c = makeWindow()
        let first = try rootAgent(c)
        let second = try run("claude", from: nil, in: c)
        let helper = try run("claude", from: second, in: c)
        XCTAssertEqual(items(c).map(\.id), [first.id, second.id, helper.id], "precondition: working sorts first")

        report(.blocked(.permission), from: helper)

        XCTAssertEqual(items(c).map(\.id), [second.id, helper.id, first.id])
        XCTAssertEqual(try row(of: helper, in: c).dotForTesting.state, .blocked)
        XCTAssertNotEqual(try row(of: second, in: c).dotForTesting.state, .blocked, "the parent took its helper's dot")
    }

    func test_clickingAChildRowOpensItsTab() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let helper = try run("claude", from: root, in: c)
        let showing = c.activeTabIDForTesting

        try click(try row(of: helper, in: c))

        XCTAssertNotEqual(c.activeTabIDForTesting, showing)
        XCTAssertEqual(c.activeTabIDForTesting, c.pane(token: helper.token)?.tab)
        XCTAssertEqual(c.focusedSurfaceIDForTesting, helper.id)
    }

    func test_whenTheParentAgentLeaves_itsChildrenBecomeTopLevelRows() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let helper = try run("claude", from: root, in: c)
        let process = try run("htop", from: root, in: c)

        root.surface.delegate?.surface(
            root.surface, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        drainMainQueue()

        XCTAssertNil(rows(c).first { $0.itemForTesting?.id == root.id }, "precondition: the parent left")
        XCTAssertEqual(Set(items(c).map(\.id)), [helper.id, process.id])
        XCTAssertEqual(try row(of: helper, in: c).itemForTesting?.role, .agent)
        XCTAssertEqual(try row(of: helper, in: c).frame.height, SidebarAgentRow.height)
        XCTAssertEqual(try row(of: process, in: c).itemForTesting?.role, .process(nested: false))
        XCTAssertFalse(try row(of: process, in: c).isNestedForTesting)
    }

    func test_whenTheParentPaneCloses_childrenThatOutliveItBecomeTopLevelRows() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let parent = try run("claude", from: root, in: c)
        let child = try run("claude", from: parent, outlivesParent: true, in: c)
        XCTAssertEqual(try row(of: child, in: c).itemForTesting?.role, .helper, "precondition")

        responder(c).respond(
            to: ControlRequest(id: 2, cmd: .paneClose, args: ControlArgs(pane: .token(parent.token)), caller: nil)
        ) { _ in }
        drainMainQueue()

        XCTAssertNil(rows(c).first { $0.itemForTesting?.id == parent.id }, "precondition: the parent closed")
        XCTAssertEqual(items(c).map(\.id), [root.id, child.id])
        XCTAssertEqual(try row(of: child, in: c).itemForTesting?.role, .agent)
    }

    func test_aProcessRowLeavesWhenItsProcessExits() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let process = try run("htop", from: root, in: c)
        XCTAssertNotNil(rows(c).first { $0.itemForTesting?.id == process.id }, "precondition")

        process.surface.delegate?.surface(
            process.surface, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        process.surface.delegate?.surfaceDidExit(process.surface, code: 0)
        drainMainQueue()

        XCTAssertEqual(items(c).map(\.id), [root.id])
    }

    func test_aKeptProcessRowLeavesWhenItsProcessFallsIdle() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let process = try run("htop", from: root, keep: true, in: c)
        process.surface.isBusy = true
        c.trackAgentExitsForTesting()
        XCTAssertNotNil(rows(c).first { $0.itemForTesting?.id == process.id }, "precondition")

        process.surface.isBusy = false
        c.trackAgentExitsForTesting()

        XCTAssertEqual(items(c).map(\.id), [root.id])
        XCTAssertNotNil(c.pane(token: process.token), "precondition: the kept pane is still open")
    }

    func test_aKeptProcessThatFinishesBetweenPolls_leavesOnItsFinishMark() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let process = try run("make", from: root, keep: true, in: c)
        XCTAssertNotNil(rows(c).first { $0.itemForTesting?.id == process.id }, "precondition")
        let script = process.surface.lastConfig?.args.last ?? ""
        XCTAssertTrue(script.contains("133;D"), "a kept run reports no finish mark: \(script)")
        XCTAssertTrue(script.contains("exec "), "precondition: a kept run keeps its shell")

        process.surface.delegate?.surface(
            process.surface, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        drainMainQueue()
        c.trackAgentExitsForTesting()

        XCTAssertEqual(items(c).map(\.id), [root.id], "a process never seen busy stayed listed")
        XCTAssertNotNil(c.pane(token: process.token), "precondition: the kept pane is still open")
    }

    func test_aKeptHelperWhoseAgentLeftIsNotListedAsAProcess() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let helper = try run("claude", from: root, keep: true, in: c)

        helper.surface.delegate?.surface(
            helper.surface, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 1))
        drainMainQueue()

        XCTAssertEqual(items(c).map(\.id), [root.id])
    }

    func test_aHelpersHelperListsUnderTheTopAgent_namingTheHelperThatStartedIt() throws {
        let c = makeWindow()
        let root = try rootAgent(c)
        let helper = try run("claude", from: root, in: c)
        report(.working, from: helper)
        let grandchild = try run("htop", from: helper, in: c)
        let helperTitle = try XCTUnwrap(try row(of: helper, in: c).itemForTesting?.summary)

        XCTAssertEqual(items(c).map(\.id), [root.id, helper.id, grandchild.id])
        let row = try row(of: grandchild, in: c)
        XCTAssertEqual(row.itemForTesting?.role, .process(nested: true))
        XCTAssertEqual(row.itemForTesting?.startedBy, helperTitle)
        XCTAssertEqual(row.tooltipForTesting, "Started by \(helperTitle)")
        XCTAssertNil(try self.row(of: helper, in: c).itemForTesting?.startedBy, "its parent is the top agent")
    }
}
