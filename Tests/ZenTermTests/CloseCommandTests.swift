import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class CloseCommandTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

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
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.mountAndStart()
        c.floatsForTesting.resolveRepoRoot = { $1($0) }
        controller = c
        return c
    }

    private func onScreen() -> WindowController {
        let c = makeWindow()
        c.window.makeKeyAndOrderFront(nil)
        return c
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func toastText(_ c: WindowController) -> [String] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
            .flatMap { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
    }

    private func pressClose(_ c: WindowController) throws {
        let content = try XCTUnwrap(c.window.contentView)
        let button = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? AppButton }.first { $0.title == "Close" })
        button.performClick(nil)
        drainMainQueue()
    }

    private func firstPane() throws -> RecordingSurface {
        try XCTUnwrap(spawned.first)
    }

    private func middleClick(tab index: Int, in c: WindowController) throws {
        let content = try XCTUnwrap(c.window.contentView)
        content.layoutSubtreeIfNeeded()
        let chips = descendants(of: content)
            .filter { String(describing: type(of: $0)) == "Chip" }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let chip = try XCTUnwrap(chips.indices.contains(index) ? chips[index] : nil, "no tab \(index)")
        let cg = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                mouseButton: .center))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.buttonNumber, 2, "a middle click is AppKit button 2")
        chip.otherMouseDown(with: event)
        drainMainQueue()
    }

    private func configureFloat(_ id: String, persist: ToolFloat.Persistence) {
        var config = GeneralConfig.builtIn
        config.floats = [
            ToolFloat(
                id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon,
                command: id, dir: nil, widthFraction: 0.85, heightFraction: 0.85,
                requiresGitRepo: false, persist: persist,
                toggle: Chord(command: true, shift: true, key: "j"))
        ]
        GeneralConfig.setCurrentForTesting(config)
    }

    private func openRunningFloat(_ c: WindowController, _ id: String) throws {
        let before = spawned.count
        c.handle(.toggleToolFloat(id))
        try XCTUnwrap(spawned.dropFirst(before).first, "opening the float spawns a shell").isBusy = true
    }

    private func activePane(_ c: WindowController) throws -> RecordingSurface {
        let tab = try XCTUnwrap(c.activeTabIDForTesting)
        let controller = try XCTUnwrap(c.controllerForTesting(tab: tab))
        return try XCTUnwrap(controller.allSurfaces.first as? RecordingSurface)
    }

    private func spareTab(_ c: WindowController) {
        c.newTabForTesting()
        c.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func split(
        _ c: WindowController, _ count: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        for i in 0..<count {
            c.handle(i.isMultiple(of: 2) ? .splitVertical : .splitHorizontal)
            c.window.contentView?.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(
            c.activeTabIDForTesting.flatMap { c.controllerForTesting(tab: $0)?.allSurfaces.count },
            count + 1, "the splits have to take, or the close is not being asked anything",
            file: file, line: line)
    }

    private func hiddenDrawer(_ c: WindowController, _ chord: KeyInterceptor.ReservedChord) throws
        -> RecordingSurface
    {
        let before = spawned.count
        c.handle(chord)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first, "opening the drawer spawns a shell")
        c.handle(chord)
        drainMainQueue()
        return drawer
    }

    private func hiddenScratch(_ c: WindowController) throws -> RecordingSurface {
        let before = spawned.count
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let scratch = try XCTUnwrap(spawned.dropFirst(before).first, "opening Scratch spawns a shell")
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        drainMainQueue()
        return scratch
    }

    func test_closePane_closesThePane_andLeavesTheTab() throws {
        let c = makeWindow()
        split(c, 1)
        let tab = try XCTUnwrap(c.activeTabIDForTesting)

        c.handle(.closePane)

        XCTAssertEqual(c.activeTabIDForTesting, tab, "the tab outlives one of its panes")
        XCTAssertEqual(c.controllerForTesting(tab: tab)?.allSurfaces.count, 1)
    }

    func test_closePane_onTheLastPane_closesTheTab() {
        let c = makeWindow()
        c.newTabForTesting()
        XCTAssertEqual(c.tabOrderForTesting.count, 2)

        c.handle(.closePane)

        XCTAssertEqual(c.tabOrderForTesting.count, 1)
    }

    func test_closePane_onTheLastTab_closesItsWorkspace_andShowsWhatIsLeft() {
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        let other = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(other)

        c.handle(.closePane)

        XCTAssertEqual(c.workspaceIDsForTesting, [home])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, home)
    }

    func test_closePane_onTheLastTabOfTheLastWorkspace_asksBeforeTakingTheWindow() throws {
        let c = onScreen()

        c.handle(.closePane)

        XCTAssertTrue(c.isConfirmOpen, "the window goes with it, so it says so first")
        XCTAssertTrue(c.window.isVisible, "the window waits on the answer")
        XCTAssertTrue(toastText(c).contains("Close Window"))
        XCTAssertTrue(
            toastText(c).contains("Closing this pane will close the window."),
            "nothing is running, so the sentence is only the consequence")

        try pressClose(c)

        XCTAssertFalse(c.window.isVisible)
    }

    func test_closePane_onTheLastTabOfTheLastWorkspace_cancelKeepsEverything() {
        let c = onScreen()

        c.handle(.closePane)
        c.handle(.closePane)

        XCTAssertTrue(c.window.isVisible)
        XCTAssertEqual(c.tabOrderForTesting.count, 1)
        XCTAssertEqual(
            c.activeTabIDForTesting.flatMap { c.controllerForTesting(tab: $0)?.allSurfaces.count }, 1,
            "a second ⌘W is swallowed by the open card, it does not close the pane behind it")
    }

    func test_closePane_takingTheWindow_withSomethingRunning_saysBoth() throws {
        let c = onScreen()
        try hiddenDrawer(c, .toggleBottomDrawer).isBusy = true

        c.handle(.closePane)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this pane will close the window and stop everything running in it, "
                    + "including the bottom drawer."))
    }

    func test_closeTab_closesTheWholeTab_whateverThePaneCount() {
        let c = makeWindow()
        c.newTabForTesting()
        c.window.contentView?.layoutSubtreeIfNeeded()
        split(c, 2)

        c.handle(.closeTab)

        XCTAssertEqual(c.tabOrderForTesting.count, 1, "three panes go with the tab, not one at a time")
    }

    func test_closeTab_onTheLastTabOfTheLastWorkspace_asksBeforeTakingTheWindow() throws {
        let c = onScreen()

        c.handle(.closeTab)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(
            toastText(c).contains("Closing this tab will close the window."))

        try pressClose(c)

        XCTAssertFalse(c.window.isVisible)
    }

    func test_closeWindow_closesTheWindow() {
        let c = onScreen()
        XCTAssertTrue(c.window.isVisible)

        c.handle(.closeWindow)

        XCTAssertFalse(c.window.isVisible)
    }

    func test_closeWindow_withSomethingRunning_asksFirst() throws {
        let c = onScreen()
        try firstPane().isBusy = true

        c.handle(.closeWindow)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(c.window.isVisible, "the window waits on the answer")
        try pressClose(c)
        XCTAssertFalse(c.window.isVisible)
    }

    func test_closeWindow_withOneWorkspace_namesNothing() throws {
        let c = onScreen()
        try firstPane().isBusy = true

        c.handle(.closeWindow)

        XCTAssertTrue(
            toastText(c).contains("Closing this window will stop everything running in it."),
            "one workspace is the only place it could be, so naming it says nothing")
    }

    func test_closeWindow_withOneWorkspace_stillNamesAFloatRunningOutOfSight() throws {
        configureFloat("btop", persist: .window)
        let c = onScreen()
        let before = spawned.count
        c.handle(.toggleToolFloat("btop"))
        let float = try XCTUnwrap(spawned.dropFirst(before).first)
        float.isBusy = true
        c.handle(.toggleToolFloat("btop"))
        drainMainQueue()

        c.handle(.closeWindow)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this window will stop everything running in it, including btop."),
            "a tool running out of sight is the one thing the window close has to say")
    }

    func test_closeWindow_withOneWorkspace_namesTheTabsWithSomethingRunning() throws {
        let c = onScreen()
        c.renameActiveTabForTesting(to: "api")
        spareTab(c)
        c.renameActiveTabForTesting(to: "web")
        try activePane(c).isBusy = true

        c.handle(.closeWindow)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this window will stop everything running in it, including web."),
            "one workspace with several tabs names the tabs, not nothing")
    }

    func test_closeWindow_withOneWorkspaceAndOneTab_namesThatTabsHiddenSurfaces() throws {
        let c = onScreen()
        try hiddenDrawer(c, .toggleBottomDrawer).isBusy = true

        c.handle(.closeWindow)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this window will stop everything running in it, including the bottom drawer."),
            "the same drawer ⌘W names, named the same way")
    }

    func test_closeWindow_withAnOpenEphemeralFloatRunning_asksFirst() throws {
        configureFloat("yazi", persist: .ephemeral)
        let c = onScreen()
        try openRunningFloat(c, "yazi")

        c.handle(.closeWindow)

        XCTAssertTrue(c.isConfirmOpen, "an ephemeral float is running on screen, so closing ends it")
        XCTAssertTrue(c.window.isVisible)
    }

    func test_closeTab_takingTheWindow_withAnOpenEphemeralFloatRunning_saysSo() throws {
        configureFloat("yazi", persist: .ephemeral)
        let c = onScreen()
        try openRunningFloat(c, "yazi")

        c.handle(.closeTab)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this tab will close the window and stop everything running in it."))
    }

    func test_middleClickingAnIdleTab_closesItStraightAway() throws {
        let c = makeWindow()
        spareTab(c)

        try middleClick(tab: 1, in: c)

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertEqual(c.tabOrderForTesting.count, 1)
    }

    func test_middleClickingARunningTab_asksFirst() throws {
        let c = makeWindow()
        spareTab(c)
        try activePane(c).isBusy = true

        try middleClick(tab: 1, in: c)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertEqual(c.tabOrderForTesting.count, 2, "the tab waits on the answer")
        XCTAssertTrue(toastText(c).contains("Closing this tab will stop everything running in it."))
    }

    func test_middleClickingTheLastTab_asksBeforeTakingTheWindow() throws {
        let c = onScreen()

        try middleClick(tab: 0, in: c)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(c.window.isVisible)
        XCTAssertTrue(toastText(c).contains("Closing this tab will close the window."))
    }

    func test_theWindowCloseButton_withSomethingRunning_asksFirst() throws {
        let c = onScreen()
        try firstPane().isBusy = true

        c.window.performClose(nil)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(c.window.isVisible, "the window waits on the answer")
        try pressClose(c)
        XCTAssertFalse(c.window.isVisible)
    }

    func test_theWindowCloseButton_withNothingRunning_closesStraightAway() {
        let c = onScreen()

        c.window.performClose(nil)

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertFalse(c.window.isVisible)
    }

    func test_closingTabsAtAPath_takesTheWindowWithoutAsking() throws {
        let c = onScreen()
        try firstPane().isBusy = true

        c.closeTabs(atPath: root)

        XCTAssertFalse(c.isConfirmOpen, "worktree removal already asked, upstream of this")
        XCTAssertFalse(c.window.isVisible)
    }

    func test_closeWindow_namesTheWorkspacesWithSomethingRunning() throws {
        let c = onScreen()
        try firstPane().isBusy = true
        _ = c.addWorkspaceForTesting(name: "Other", folder: root)

        c.handle(.closeWindow)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this window will stop everything running in it, including Workspace 1."))
    }

    func test_closeTab_withOnlyAVisiblePaneRunning_namesNothing() throws {
        let c = makeWindow()
        spareTab(c)
        try activePane(c).isBusy = true

        c.handle(.closeTab)

        XCTAssertTrue(
            toastText(c).contains("Closing this tab will stop everything running in it."),
            "a pane is on screen to look at, so naming it says nothing new")
    }

    func test_closeTab_withARunningHiddenDrawer_namesTheDrawer() throws {
        let c = makeWindow()
        spareTab(c)
        try hiddenDrawer(c, .toggleBottomDrawer).isBusy = true

        c.handle(.closeTab)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this tab will stop everything running in it, including the bottom drawer."))
    }

    func test_closeTab_withARunningScratch_namesScratch() throws {
        let c = makeWindow()
        spareTab(c)
        try hiddenScratch(c).isBusy = true

        c.handle(.closeTab)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this tab will stop everything running in it, including Scratch."))
    }

    func test_closeTab_withSeveralRunning_readsAsAList() throws {
        let c = makeWindow()
        spareTab(c)
        try hiddenDrawer(c, .toggleBottomDrawer).isBusy = true
        try hiddenDrawer(c, .toggleRightDrawer).isBusy = true
        try hiddenScratch(c).isBusy = true

        c.handle(.closeTab)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this tab will stop everything running in it, including the bottom drawer, "
                    + "the right drawer and Scratch."))
    }

    func test_closePane_onTheLastPane_withARunningHiddenDrawer_asksAsTheTab() throws {
        let c = makeWindow()
        spareTab(c)
        try hiddenDrawer(c, .toggleRightDrawer).isBusy = true

        c.handle(.closePane)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(toastText(c).contains("Close Tab"))
        XCTAssertTrue(
            toastText(c).contains(
                "Closing this tab will stop everything running in it, including the right drawer."))
    }

    private func pressCancel(_ c: WindowController) throws {
        let content = try XCTUnwrap(c.window.contentView)
        let button = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? AppButton }.first { $0.title == "Cancel" })
        button.performClick(nil)
        drainMainQueue()
    }

    private func openSecondWorkspace(_ c: WindowController, named name: String) -> WorkspaceID {
        let id = c.addWorkspaceForTesting(name: name, folder: root)
        c.activateWorkspaceForTesting(id)
        return id
    }

    func test_closeWorkspace_withNothingRunning_closesAtOnce_andLandsOnItsNeighbour() throws {
        let c = onScreen()
        let home = c.activeWorkspaceIDForTesting
        _ = openSecondWorkspace(c, named: "api")
        let api = try activePane(c)

        c.handle(.closeWorkspace)

        XCTAssertFalse(c.isConfirmOpen, "nothing is running, so it does not ask")
        XCTAssertEqual(c.workspaceIDsForTesting, [home])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, home)
        XCTAssertTrue(api.terminated, "its shells stop")
    }

    func test_closeWorkspace_closesEveryTabInIt() throws {
        let c = onScreen()
        _ = openSecondWorkspace(c, named: "api")
        let first = try activePane(c)
        spareTab(c)
        let second = try activePane(c)

        c.handle(.closeWorkspace)

        XCTAssertTrue(first.terminated)
        XCTAssertTrue(second.terminated)
        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
    }

    func test_closeWorkspace_withSomethingRunning_asksFirst_namingTheRunningTab() throws {
        let c = onScreen()
        _ = openSecondWorkspace(c, named: "zen-review")
        c.renameActiveTabForTesting(to: "codex")
        try activePane(c).isBusy = true

        c.handle(.closeWorkspace)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(toastText(c).contains("Close Workspace"))
        XCTAssertTrue(
            toastText(c).contains("Closing zen-review will stop everything running in it, including codex."))

        try pressClose(c)

        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
    }

    func test_closeWorkspace_withSomethingRunning_cancelKeepsIt() throws {
        let c = onScreen()
        let api = openSecondWorkspace(c, named: "api")
        let pane = try activePane(c)
        pane.isBusy = true

        c.handle(.closeWorkspace)
        try pressCancel(c)

        XCTAssertEqual(c.activeWorkspaceIDForTesting, api)
        XCTAssertFalse(pane.terminated)
    }

    func test_closeWorkspace_onTheLastOne_alwaysAsks_thenClosesTheWindow() throws {
        let c = onScreen()

        c.handle(.closeWorkspace)

        XCTAssertTrue(c.isConfirmOpen, "the window goes with it, so it says so first")
        XCTAssertTrue(toastText(c).contains("Close Window"))
        XCTAssertTrue(toastText(c).contains("Closing this workspace will close the window."))

        try pressClose(c)

        XCTAssertFalse(c.window.isVisible)
    }

    func test_closeWorkspace_onTheLastOne_withSomethingRunning_saysBoth() throws {
        let c = onScreen()
        c.renameActiveTabForTesting(to: "api")
        spareTab(c)
        c.renameActiveTabForTesting(to: "claude")
        try activePane(c).isBusy = true

        c.handle(.closeWorkspace)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this workspace will close the window and stop everything running in it, "
                    + "including claude."))
    }

    func test_closingABackgroundWorkspace_byItsID_leavesTheActiveOneOnScreen() throws {
        let c = onScreen()
        let home = c.activeWorkspaceIDForTesting
        let homeCanvas = try XCTUnwrap(c.activeTabIDForTesting.flatMap { c.controllerForTesting(tab: $0) }).view
        let api = c.addWorkspaceForTesting(name: "api", folder: root)
        let apiCanvas = try XCTUnwrap(
            c.tabIDsForTesting(workspace: api).first.flatMap { c.controllerForTesting(tab: $0) }
        ).view

        c.requestCloseWorkspace(id: api)

        XCTAssertEqual(c.workspaceIDsForTesting, [home])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, home)
        XCTAssertNotNil(homeCanvas.superview, "the active canvas never leaves the screen")
        XCTAssertNil(apiCanvas.superview, "the closing workspace is never mounted")
    }

    func test_cmdOptW_throughTheInterceptor_closesTheWorkspace() throws {
        let c = onScreen()
        _ = openSecondWorkspace(c, named: "api")
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.onReservedChord = { c.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: 0, context: nil, characters: "∑", charactersIgnoringModifiers: "w",
                isARepeat: false, keyCode: 13))

        XCTAssertNil(keys.route(event), "⌘⌥W is claimed, not passed to the pane")
        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
    }
}
