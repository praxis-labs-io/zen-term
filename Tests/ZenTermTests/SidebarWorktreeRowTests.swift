import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SidebarWorktreeRowTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var tempRoot: URL!
    private var spawned: [RecordingSurface] = []

    private let alpha = URL(fileURLWithPath: NSString("~/Dev/alpha").expandingTildeInPath, isDirectory: true)

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
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-sidebar-worktrees-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        try """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        """.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        SidebarController.resetLastChoiceForTesting()
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func openPicker(in c: WindowController) throws -> RepoPickerOverlay {
        c.handle(.toggleRepoPicker)
        waitUntil(pickers(in: c).first != nil, "the picker to be presented")
        return try XCTUnwrap(pickers(in: c).first)
    }

    private func pickers(in c: WindowController) -> [RepoPickerOverlay] {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }
    }

    private func searchField(of picker: RepoPickerOverlay) throws -> NSTextField {
        try XCTUnwrap(
            descendants(of: picker).compactMap { $0 as? NSTextField }
                .first { ($0.delegate as? PaletteOverlay) === picker })
    }

    // Arrows onto the named row and opens it, so a test says which workspace it means.
    private func choose(_ name: String, in picker: RepoPickerOverlay) throws {
        let field = try searchField(of: picker)
        guard
            let index = picker.rowViews.firstIndex(where: { view in
                guard let row = view as? RepoPickerOverlay.RowView else { return false }
                if let running = row.running { return running.id != nil && running.name == name }
                if let worktree = row.worktree { return (worktree.branch ?? worktree.head) == name }
                return row.label == name
            })
        else { return XCTFail("the picker has no row for \(name)") }
        for _ in 0..<picker.rowViews.count where picker.selected != index {
            _ = picker.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        }
        XCTAssertEqual(picker.selected, index, "the arrows never reached \(name)")
        _ = picker.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func openWorkspace(named name: String, in c: WindowController) throws {
        try choose(name, in: try openPicker(in: c))
    }

    // ⌘P lists a worktree only under a Configured parent, and these tests open one under a live parent.
    private func openAlphaWorktree(branch: String?, head: String = "a41c9e2d0f", in c: WindowController) throws {
        let worktree = Worktree(
            path: alpha.appendingPathComponent(branch ?? head, isDirectory: true), branch: branch, head: head,
            isLocked: false)
        let parent = try XCTUnwrap(
            ConfigLoader.loadWorkspacesBlocking().first { $0.path.standardizedFileURL == alpha.standardizedFileURL },
            "Alpha is not in the seeded workspaces file")
        c.openWorkspaceForTesting(
            RepoPickerOverlay.workspace(
                for: worktree, parent: parent, repoRoot: GitRepoStatus.repoRoot(parent.path)),
            origin: WorktreeOrigin(parent: parent, worktree: worktree))
    }

    private func rows(of c: WindowController) -> [SettingsNavRow] { c.sidebarForTesting.view.rowsForTesting }

    private func toastTexts(in c: WindowController) -> [String] {
        descendants(of: c.window.contentView!).compactMap { $0 as? ToastView }
            .flatMap { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
    }

    func test_aWorktreeRemovedOutsideZenTerm_staysOpenAndSaysSo() throws {
        let c = makeWindow()
        try openWorkspace(named: "Alpha", in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        let tabs = c.tabOrderForTesting.count
        WorktreeStore.isRemovedOverrideForTesting = { _ in true }

        c.checkForRemovedWorktreesForTesting()
        waitUntil(rows(of: c).contains { $0.detailForTesting == "removed" }, "the row to say it was removed")

        let row = try XCTUnwrap(rows(of: c).first { $0.titleForTesting == "feature/one" })
        XCTAssertEqual(row.detailForTesting, "removed")
        XCTAssertEqual(c.tabOrderForTesting.count, tabs, "its panes keep running")
        XCTAssertTrue(toastTexts(in: c).contains("Worktree Removed"))
        XCTAssertTrue(toastTexts(in: c).contains("feature/one is no longer on disk."))

        WorktreeStore.isRemovedOverrideForTesting = { _ in false }
        c.checkForRemovedWorktreesForTesting()
        waitUntil(!rows(of: c).contains { $0.detailForTesting == "removed" }, "the mark to clear when .git is back")
    }

    func test_removeWorktreeOnARemovedRow_closesItsWorkspace() throws {
        let c = makeWindow()
        try openWorkspace(named: "Alpha", in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        WorktreeStore.isRemovedOverrideForTesting = { _ in true }
        c.checkForRemovedWorktreesForTesting()
        waitUntil(rows(of: c).contains { $0.detailForTesting == "removed" }, "the row to say it was removed")
        let picker = try openPicker(in: c)
        let field = try searchField(of: picker)
        let index = try XCTUnwrap(
            picker.rowViews.firstIndex { ($0 as? RepoPickerOverlay.RowView)?.running?.removedWorktree != nil })
        for _ in 0..<picker.rowViews.count where picker.selected != index {
            _ = picker.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        }

        c.handle(.removeWorktree)

        XCTAssertTrue(pickers(in: c).isEmpty, "the picker steps aside for the close")
        XCTAssertFalse(titles(of: c).contains("feature/one"), "the workspace closes")
        XCTAssertTrue(titles(of: c).contains("Alpha"), "and only that one")
    }

    func test_aWorktreeZenTermIsRemoving_isNotMarkedRemoved() throws {
        let c = makeWindow()
        try openWorkspace(named: "Alpha", in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        c.worktreeRemovals.begin(alpha.appendingPathComponent("feature/one", isDirectory: true))
        var checked = false
        WorktreeStore.isRemovedOverrideForTesting = { _ in
            checked = true
            return true
        }

        c.checkForRemovedWorktreesForTesting()
        waitUntil(checked, "the check to run")
        drainMainQueue()

        XCTAssertFalse(rows(of: c).contains { $0.detailForTesting == "removed" })
        XCTAssertFalse(toastTexts(in: c).contains("Worktree Removed"))
    }

    private func titles(of c: WindowController) -> [String] { rows(of: c).map(\.titleForTesting) }

    private func click(_ row: SettingsNavRow) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        row.mouseDown(with: event)
    }

    private func press(_ key: String, typing characters: String, keyCode: UInt16, in c: WindowController) throws {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { c.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: keyCode))
        XCTAssertNil(keys.route(event), "the chord is claimed, not passed to the pane")
    }

    func test_aWorktreeOpenedFromThePicker_withItsWorkspaceClosed_nestsUnderAGhostRow() throws {
        let c = makeWindow()

        try openAlphaWorktree(branch: "feature/one", in: c)

        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one"])
        let ghost = rows(of: c)[1]
        XCTAssertEqual(ghost.variant, .faint)
        XCTAssertEqual(ghost.titleInkForTesting, Theme.current.chrome.ink(.faint))
        XCTAssertEqual(ghost.detailForTesting, "")
        XCTAssertNil(ghost.tooltip, "a ghost takes no ⌘⌃ number")
        XCTAssertEqual(rows(of: c)[2].variant, .nested(symbol: "arrow.triangle.branch"))
        XCTAssertEqual(rows(of: c)[2].layer?.backgroundColor, Theme.current.chrome.fill(.rest).cgColor)
    }

    func test_clickingTheGhost_opensItsWorkspaceInThatPlace() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)

        try click(rows(of: c)[1])

        waitUntil(c.workspaceNamesForTesting.count == 3, "the workspace to open")
        XCTAssertEqual(c.workspaceNamesForTesting, ["Workspace 1", "Alpha: feature/one", "Alpha"])
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one"])
        XCTAssertEqual(rows(of: c).map(\.variant), [.standard, .standard, .nested(symbol: "arrow.triangle.branch")])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting[2])
    }

    private func rewriteWorkspaces(_ contents: String) throws {
        try contents.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    func test_clickingTheGhost_opensItsWorkspaceAsTheFileNowHasIt() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)
        try rewriteWorkspaces("[Alpha Renamed]\npath = ~/Dev/alpha\n")

        try click(rows(of: c)[1])

        waitUntil(c.workspaceNamesForTesting.count == 3, "the workspace to open")
        XCTAssertEqual(c.workspaceNamesForTesting.last, "Alpha Renamed")
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha Renamed", "feature/one"])
    }

    func test_clickingTheGhost_withItsEntryGone_opensItAsItWasWhenTheWorktreeOpened() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)
        try rewriteWorkspaces("[Beta]\npath = ~/Dev/beta\n")

        try click(rows(of: c)[1])

        waitUntil(c.workspaceNamesForTesting.count == 3, "the workspace to open")
        XCTAssertEqual(c.workspaceNamesForTesting.last, "Alpha")
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one"])
    }

    func test_closingTheLastWorktree_takesItsGhostWithIt() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one"])

        c.handle(.closeTab)

        XCTAssertEqual(titles(of: c), ["Workspace 1"])
    }

    func test_aWorktreeOpenedLast_nestsUnderItsOpenWorkspace() throws {
        let c = makeWindow()
        try openWorkspace(named: "Alpha", in: c)
        try openWorkspace(named: "Beta", in: c)

        try openAlphaWorktree(branch: "feature/one", in: c)

        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one", "Beta"])
    }

    func test_aDetachedWorktree_isNamedByItsShortHash() throws {
        let c = makeWindow()

        try openAlphaWorktree(branch: nil, in: c)

        XCTAssertEqual(titles(of: c).last, "a41c9e2")
    }

    func test_cmdCtrlDigits_followTheSidebar_nestedWorktreesIncluded() throws {
        let c = makeWindow()
        try openWorkspace(named: "Alpha", in: c)
        try openWorkspace(named: "Beta", in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        let worktree = c.activeWorkspaceIDForTesting
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one", "Beta"])

        try press("1", typing: "1", keyCode: 18, in: c)
        try press("3", typing: "3", keyCode: 20, in: c)

        XCTAssertEqual(c.activeWorkspaceIDForTesting, worktree)
    }

    func test_rowTooltips_numberTheSidebar_skippingTheGhost() throws {
        let c = makeWindow()
        try openWorkspace(named: "Beta", in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Beta", "Alpha", "feature/one"])

        let shortcuts = rows(of: c).map { $0.tooltip?.shortcutForTesting }

        XCTAssertEqual(shortcuts, ["⌘⌃1", "⌘⌃2", nil, "⌘⌃3"])
    }

    func test_cmdCtrlBrackets_stepThroughTheSidebar_nestedWorktreesIncluded() throws {
        let c = makeWindow()
        try openWorkspace(named: "Alpha", in: c)
        try openWorkspace(named: "Beta", in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        let ids = c.workspaceIDsForTesting
        c.activateWorkspaceForTesting(ids[1])

        try press("]", typing: "\u{1d}", keyCode: 30, in: c)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, ids[3], "Alpha's worktree follows Alpha")

        try press("]", typing: "\u{1d}", keyCode: 30, in: c)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, ids[2], "Beta follows the worktree")
    }

    private var menu: SidebarRowMenu { controller!.sidebarForTesting.view.rowMenu }

    private func rightClick(_ row: SettingsNavRow) throws {
        row.rightMouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1)))
    }

    func test_aWorktreeRowsMenu_offersOnlyClose_andAGhostsOnlyNewWorktree() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)

        try rightClick(rows(of: c)[2])
        XCTAssertEqual(menu.itemViewsForTesting.map(\.title), ["Close Workspace"])

        try rightClick(rows(of: c)[1])
        XCTAssertEqual(menu.itemViewsForTesting.map(\.title), ["New Worktree…"], "a ghost is not open to close")
    }

    func test_closeFromTheMenu_closesThatWorkspace_evenInTheBackground() throws {
        let c = makeWindow()
        try openWorkspace(named: "Alpha", in: c)
        try openWorkspace(named: "Beta", in: c)
        let beta = c.activeWorkspaceIDForTesting

        try rightClick(rows(of: c)[1])
        try XCTUnwrap(menu.itemViewsForTesting.last).mouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))

        XCTAssertEqual(titles(of: c), ["Workspace 1", "Beta"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, beta, "closing a background workspace leaves the screen alone")
        XCTAssertFalse(menu.isOpen)
    }

    func test_closingAWorkspace_landsOnItsNeighbourInTheSidebar_andLeavesItsWorktreeUnderAGhost() throws {
        let c = makeWindow()
        try openWorkspace(named: "Alpha", in: c)
        try openWorkspace(named: "Beta", in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        let worktree = c.activeWorkspaceIDForTesting
        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[1])
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one", "Beta"])

        c.handle(.closeWorkspace)

        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one", "Beta"])
        XCTAssertEqual(rows(of: c)[1].variant, .faint, "Alpha's row turns ghost")
        XCTAssertEqual(c.activeWorkspaceIDForTesting, worktree, "the next row down, not the next one opened")
    }

    func test_aParentOpenedIntoItsGhostsPlace_staysThere_afterItsWorktreeCloses() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)
        try openWorkspace(named: "Beta", in: c)
        try click(rows(of: c)[1])
        waitUntil(c.workspaceNamesForTesting.count == 4, "the workspace to open")
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one", "Beta"])

        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[1])
        c.handle(.closeTab)

        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "Beta"])
    }

    func test_aBackgroundWorktreeWithAnAgentWaiting_showsTheDotOnItsRow_notTheGhosts() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)
        let agent = try XCTUnwrap(spawned.last)
        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[0])
        XCTAssertEqual(rows(of: c).map(\.showsAttentionForTesting), [false, false, false])

        agent.delegate?.surface(agent, didPostNotification: TerminalNotification(title: "", body: "Wants to run"))
        waitUntil(rows(of: c)[2].showsAttentionForTesting, "the worktree row's dot")

        XCTAssertEqual(rows(of: c).map(\.showsAttentionForTesting), [false, false, true])
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func openAlphaBetaThenAlphasWorktree(in c: WindowController) throws {
        try openWorkspace(named: "Alpha", in: c)
        try openWorkspace(named: "Beta", in: c)
        try openAlphaWorktree(branch: "feature/one", in: c)
        XCTAssertEqual(titles(of: c), ["Workspace 1", "Alpha", "feature/one", "Beta"])
    }

    func test_aBackgroundWorkspacesCard_showsItsSidebarNumber_notItsOpenOrder() throws {
        let c = makeWindow()
        try openAlphaBetaThenAlphasWorktree(in: c)
        let beta = try XCTUnwrap(c.tabIDsForTesting(workspace: c.workspaceIDsForTesting[2]).first)

        c.notifyAgentForTesting(tab: beta, message: "needs you")
        drainMainQueue()

        let card = try XCTUnwrap(c.waitingToastForTesting(tab: beta))
        let keycaps = descendants(of: card).compactMap { ($0 as? KeycapView)?.shortcut }
        XCTAssertEqual(keycaps, ["⌘⌃4"], "Beta sits fourth in the sidebar, and ⌘⌃4 is what reaches it")
    }

    func test_agentsSharingAState_listInSidebarOrder_notOpenOrder() throws {
        let c = makeWindow()
        try openAlphaBetaThenAlphasWorktree(in: c)
        XCTAssertEqual(spawned.count, 4, "precondition: one surface per workspace, in open order")
        c.activateWorkspaceForTesting(c.workspaceIDsForTesting[0])

        for agent in [spawned[2], spawned[3]] {
            agent.delegate?.surface(agent, progressDidChange: TerminalProgress(state: .indeterminate, fraction: nil))
        }
        drainMainQueue()

        let places = c.sidebarForTesting.view.agentRowsForTesting.compactMap(\.itemForTesting?.detail)
        XCTAssertEqual(places.count, 2)
        XCTAssertTrue(places[0].hasPrefix("Alpha: feature/one"), "\(places)")
        XCTAssertTrue(places[1].hasPrefix("Beta"), "\(places)")
    }

    func test_collapsedLead_readsWorkspaceSlashWorktree_whileAWorktreeIsActive() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/one", in: c)
        c.handle(.toggleSidebar)

        XCTAssertEqual(c.sidebarForTesting.lead.workspaceNameForTesting, "Alpha / feature/one")

        try press("1", typing: "1", keyCode: 18, in: c)

        XCTAssertEqual(c.sidebarForTesting.lead.workspaceNameForTesting, "Workspace 1")
    }

    func test_collapsedLead_cutsALongWorktreeAtAWholeCharacter_soTheDividerKeepsItsGap() throws {
        let c = makeWindow()
        try openAlphaWorktree(branch: "feature/zen-532-make-a-new-workspace-without-a-config-entry", in: c)
        c.handle(.toggleSidebar)
        c.containerForTesting.layoutSubtreeIfNeeded()

        let lead = c.sidebarForTesting.lead
        let name = lead.workspaceNameLabelForTesting
        XCTAssertTrue(lead.workspaceNameForTesting.hasPrefix("Alpha / feature/zen-532"))
        XCTAssertTrue(lead.workspaceNameForTesting.hasSuffix("…"))
        XCTAssertLessThanOrEqual(name.alignmentRect(forFrame: name.frame).width, TabBarView.maxChipWidth)
        XCTAssertEqual(
            name.alignmentRect(forFrame: name.frame).width, name.intrinsicContentSize.width, accuracy: 0.5,
            "the label draws all it holds, so no truncation slack sits before the divider")
    }
}
