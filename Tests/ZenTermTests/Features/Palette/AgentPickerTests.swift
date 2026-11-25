import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class AgentPickerTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var root: URL!

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
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-agent-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
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
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            initialCWD: root.appendingPathComponent("home", isDirectory: true))
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func pickers(in c: WindowController) -> [AgentPickerOverlay] {
        descendants(of: c.window.contentView!).compactMap { $0 as? AgentPickerOverlay }
    }

    private func sidebarItems(_ c: WindowController) -> [SidebarAgentItem] {
        c.sidebarForTesting.view.agentRowsForTesting.compactMap(\.itemForTesting)
    }

    private func agentRows(in picker: AgentPickerOverlay) -> [AgentPickerOverlay.AgentRowView] {
        picker.rowViews.compactMap { $0 as? AgentPickerOverlay.AgentRowView }
    }

    private func pressOpen(in c: WindowController) throws {
        try pressChord("o", [.command, .shift], keyCode: 31, in: c)
    }

    private func openPicker(in c: WindowController) throws -> AgentPickerOverlay {
        try pressOpen(in: c)
        return try XCTUnwrap(pickers(in: c).first, "⌘⇧O opened no agent picker")
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func pane(_ token: Int, in c: WindowController) throws -> Pane {
        let id = try XCTUnwrap(c.pane(token: token)?.pane.surfaceID)
        let surface = try XCTUnwrap(
            spawned.first { $0.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init) == token })
        return Pane(token: token, id: id, surface: surface)
    }

    private func rootAgent(_ c: WindowController, title: String) throws -> Pane {
        let token = try XCTUnwrap(spawned.first?.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
        let root = try pane(token, in: c)
        report(.working, title: title, from: root)
        return root
    }

    private func run(_ cmd: String, from parent: Pane, in c: WindowController) throws -> Pane {
        var reply: ControlReply?
        ControlResponder(windows: { [c] in [c] }, keyWindow: { [c] in c }).respond(
            to: ControlRequest(
                id: 1, cmd: .paneRun, args: ControlArgs(cmd: cmd), caller: ControlCaller(pane: parent.token))
        ) { reply = $0 }
        let result = try XCTUnwrap(try XCTUnwrap(reply).get() as? PaneRunResult)
        drainMainQueue()
        return try pane(result.pane, in: c)
    }

    private func report(_ state: TerminalProgramStatus.State, title: String, from pane: Pane) {
        pane.surface.delegate?.surface(
            pane.surface, programStatusDidChange: TerminalProgramStatus(state: state, app: "claude", title: title))
        drainMainQueue()
    }

    private func openWorkspace(_ title: String, running command: String, in c: WindowController) throws -> SurfaceID {
        let folder = root.appendingPathComponent(title, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        c.openWorkspaceForTesting(
            Workspace(title: title, path: folder, tabs: [Workspace.Tab(right: command)], env: [:]))
        drainMainQueue()
        return try XCTUnwrap(sidebarItems(c).first { $0.place.name == title }?.id)
    }

    private func populate(_ c: WindowController) throws -> (root: Pane, helper: Pane, process: Pane, other: SurfaceID) {
        let rootAgent = try rootAgent(c, title: "Fix the login bug")
        let helper = try run("claude", from: rootAgent, in: c)
        report(.blocked(.permission), title: "Review the token store", from: helper)
        let process = try run("make", from: rootAgent, in: c)
        let other = try openWorkspace("notes", running: "claude", in: c)
        return (rootAgent, helper, process, other)
    }

    private func type(_ query: String, into picker: AgentPickerOverlay) throws {
        let field = try XCTUnwrap(
            descendants(of: picker).compactMap { $0 as? NSTextField }.first { $0.delegate === picker })
        field.stringValue = query
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func test_commandShiftO_opensThePicker_andPressingItAgainClosesIt() throws {
        let c = makeWindow()

        try pressOpen(in: c)
        XCTAssertEqual(pickers(in: c).count, 1)

        try pressOpen(in: c)
        XCTAssertTrue(pickers(in: c).isEmpty, "a second ⌘⇧O closes it")
    }

    func test_aReboundChord_opensThePicker_andCommandShiftONoLongerDoes() throws {
        var config = GeneralConfig.builtIn
        config.rebind(.toggleAgentPicker, to: Chord(command: true, control: true, key: "o"))
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()

        try pressOpen(in: c)
        XCTAssertTrue(pickers(in: c).isEmpty, "⌘⇧O moved with the rebind")

        try pressChord("o", [.command, .control], keyCode: 31, in: c)
        XCTAssertEqual(pickers(in: c).count, 1, "the rebound chord never reached the picker")
    }

    func test_theRows_matchTheSidebarsAgentsList_groupedUnderEachRowsPlace() throws {
        let c = makeWindow()
        let (rootAgent, helper, process, other) = try populate(c)
        let home = try XCTUnwrap(sidebarItems(c).first { $0.id == rootAgent.id }).place.name

        let picker = try openPicker(in: c)

        XCTAssertEqual(
            picker.rowsForTesting,
            ["# \(home)", "Fix the login bug", "  Review the token store", "  process", "# notes", "claude"])
        let sidebar = Dictionary(uniqueKeysWithValues: sidebarItems(c).map { ($0.id, $0) })
        let rows = agentRows(in: picker)
        XCTAssertEqual(Set(rows.map(\.surface)), Set(sidebar.keys), "the same agents and processes as the sidebar")
        XCTAssertEqual(rows.map(\.surface), [rootAgent.id, helper.id, process.id, other])
        for row in rows {
            let item = try XCTUnwrap(sidebar[row.surface])
            XCTAssertEqual(row.item, item, "a row shows the sidebar's own item")
            XCTAssertEqual(row.leadingProcessForTesting, item.process, "each row leads with its chip")
            XCTAssertEqual(row.isNestedForTesting, item.role != .agent)
            XCTAssertEqual(row.showsStateForTesting, item.showsState)
        }
        XCTAssertEqual(rows[1].stateForTesting, .blocked)
        XCTAssertTrue(rows[0].isSpinningForTesting, "a working agent spins")
        XCTAssertEqual(
            picker.rowViews.compactMap { ($0 as? PaletteSectionHeader)?.title }, [home, "notes"],
            "workspace groups sit under the command palette's section headers")
    }

    func test_search_narrowsTheRows_andAMatchingHelperKeepsItsParent() throws {
        let c = makeWindow()
        let rootAgent = try populate(c).root
        let home = try XCTUnwrap(sidebarItems(c).first { $0.id == rootAgent.id }).place.name
        let picker = try openPicker(in: c)

        try type("token store", into: picker)
        XCTAssertEqual(picker.rowsForTesting, ["# \(home)", "Fix the login bug", "  Review the token store"])

        try type("notes", into: picker)
        XCTAssertEqual(picker.rowsForTesting, ["# notes", "claude"], "a workspace name matches its agents")

        try type("zzzz", into: picker)
        XCTAssertEqual(picker.rowsForTesting, [])
    }

    private func emptyState(in picker: AgentPickerOverlay) -> String? {
        descendants(of: picker).compactMap { $0 as? EmptyStateLabel }.first { !$0.isHidden }?.stringValue
    }

    func test_aWindowWithNoAgents_saysNoneAreRunning_andAQueryWithNoMatchSaysSo() throws {
        let c = makeWindow()
        let picker = try openPicker(in: c)
        XCTAssertEqual(emptyState(in: picker), AgentPickerOverlay.noAgentsText)

        try type("zzzz", into: picker)
        XCTAssertEqual(emptyState(in: picker), "No matching agents")

        try type("", into: picker)
        XCTAssertEqual(emptyState(in: picker), AgentPickerOverlay.noAgentsText)
    }

    func test_theBar_offersFocus_only() throws {
        let c = makeWindow()
        _ = try populate(c)

        let picker = try openPicker(in: c)

        XCTAssertEqual(
            picker.barHintsForTesting.map(\.label), [AgentPickerOverlay.returnAction])
    }

    func test_returnOnATabAgent_switchesToItsWorkspace_andFocusesItsPane() throws {
        let c = makeWindow()
        let rootAgent = try populate(c).root
        XCTAssertNotEqual(c.focusedSurfaceIDForTesting, rootAgent.id, "precondition: the notes workspace is showing")
        let picker = try openPicker(in: c)
        try type("Fix the login", into: picker)

        try sendKeys([.returnKey], to: c)

        XCTAssertTrue(pickers(in: c).isEmpty, "choosing closes the picker")
        XCTAssertEqual(c.focusedSurfaceIDForTesting, rootAgent.id)
    }

    func test_returnOnAFloatAgent_opensItsFloat() throws {
        let c = makeWindow()
        let (_, helper, _, _) = try populate(c)
        XCTAssertFalse(c.floatsForTesting.shownSurface === helper.surface, "precondition: the float is hidden")
        let picker = try openPicker(in: c)
        try type("token store", into: picker)
        try sendKeys([.arrowDown], to: c)

        try sendKeys([.returnKey], to: c)

        XCTAssertTrue(pickers(in: c).isEmpty)
        XCTAssertTrue(c.floatsForTesting.shownSurface === helper.surface, "the helper's float opens")
    }

    func test_aStateChangeWhileOpen_redrawsTheRow_andKeepsTheSelection() throws {
        let c = makeWindow()
        let (_, helper, _, _) = try populate(c)
        let picker = try openPicker(in: c)
        try sendKeys([.arrowDown], to: c)
        let selectedBefore = picker.selected

        report(.working, title: "Review the token store", from: helper)

        let row = try XCTUnwrap(agentRows(in: picker).first { $0.surface == helper.id })
        XCTAssertTrue(row.isSpinningForTesting, "the picker follows the sidebar's state")
        XCTAssertEqual(picker.selected, selectedBefore)
    }

    func test_anAgentsName_sitsRightAfterItsTitle_notInTheTrailingColumn() throws {
        var item = SidebarAgentItem(
            id: SurfaceID(raw: 1), state: .working, summary: "Fix the login bug", detail: "zen-term", message: nil)
        item.agentLabel = "Codex"
        let row = AgentPickerOverlay.AgentRowView(item)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PaletteOverlay.width, height: ChromeMetrics.Height.lg),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = row
        row.layoutSubtreeIfNeeded()

        let fields = descendants(of: row).compactMap { $0 as? NSTextField }
        let title = try XCTUnwrap(fields.first { $0.stringValue == "Fix the login bug" })
        let name = try XCTUnwrap(fields.first { $0.stringValue == "Codex" }, "the agent's name is not shown")
        let titleFrame = title.convert(title.bounds, to: row)
        let nameFrame = name.convert(name.bounds, to: row)
        XCTAssertGreaterThanOrEqual(nameFrame.minX, titleFrame.maxX, "the name follows the title")
        XCTAssertLessThanOrEqual(nameFrame.minX - titleFrame.maxX, ChromeMetrics.Spacing.s6, "and sits just after it")
        XCTAssertEqual(name.textColor, Theme.current.chrome.ink(.muted))
        XCTAssertEqual(row.detail, "", "the trailing column holds no qualifier")
    }
}
