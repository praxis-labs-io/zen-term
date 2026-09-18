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

    /// The tab's own pane, which `mountAndStart` spawns first.
    private func firstPane() throws -> RecordingSurface {
        try XCTUnwrap(spawned.first)
    }

    /// Lays out between splits: `split` refuses a pane whose bounds are still zero.
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

    // MARK: ⌘W, the cascade

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

    func test_closePane_onTheLastTabOfTheLastWorkspace_opensAFreshOne_andKeepsTheWindow() {
        let c = onScreen()
        let before = c.activeWorkspaceIDForTesting

        c.handle(.closePane)

        XCTAssertTrue(c.window.isVisible, "the window must never close as a side effect of ⌘W")
        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
        XCTAssertNotEqual(c.activeWorkspaceIDForTesting, before, "the emptied workspace is replaced")
        XCTAssertEqual(c.tabOrderForTesting.count, 1, "the fresh workspace opens with one tab")
    }

    // MARK: ⌘⌃W, the tab

    func test_closeTab_closesTheWholeTab_whateverThePaneCount() {
        let c = makeWindow()
        c.newTabForTesting()
        c.window.contentView?.layoutSubtreeIfNeeded()
        split(c, 2)

        c.handle(.closeTab)

        XCTAssertEqual(c.tabOrderForTesting.count, 1, "three panes go with the tab, not one at a time")
    }

    func test_closeTab_onTheLastTabOfTheLastWorkspace_opensAFreshOne_andKeepsTheWindow() {
        let c = onScreen()
        let before = c.activeWorkspaceIDForTesting

        c.handle(.closeTab)

        XCTAssertTrue(c.window.isVisible)
        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
        XCTAssertNotEqual(c.activeWorkspaceIDForTesting, before)
    }

    // MARK: ⌘⇧W, the window

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

    func test_closeWindow_namesTheWorkspacesWithSomethingRunning() throws {
        let c = onScreen()
        try firstPane().isBusy = true
        _ = c.addWorkspaceForTesting(name: "Other", folder: root)

        c.handle(.closeWindow)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this window will stop everything running in it, including Home."))
    }

    // MARK: what the confirm names

    func test_closeTab_withOnlyAVisiblePaneRunning_namesNothing() throws {
        let c = makeWindow()
        try firstPane().isBusy = true

        c.handle(.closeTab)

        XCTAssertTrue(
            toastText(c).contains("Closing this tab will stop everything running in it."),
            "a pane is on screen to look at, so naming it says nothing new")
    }

    func test_closeTab_withARunningHiddenDrawer_namesTheDrawer() throws {
        let c = makeWindow()
        try hiddenDrawer(c, .toggleBottomDrawer).isBusy = true

        c.handle(.closeTab)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this tab will stop everything running in it, including the bottom drawer."))
    }

    func test_closeTab_withARunningScratch_namesScratch() throws {
        let c = makeWindow()
        try hiddenScratch(c).isBusy = true

        c.handle(.closeTab)

        XCTAssertTrue(
            toastText(c).contains(
                "Closing this tab will stop everything running in it, including Scratch."))
    }

    func test_closeTab_withSeveralRunning_readsAsAList() throws {
        let c = makeWindow()
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
        try hiddenDrawer(c, .toggleRightDrawer).isBusy = true

        c.handle(.closePane)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertTrue(toastText(c).contains("Close Tab"))
        XCTAssertTrue(
            toastText(c).contains(
                "Closing this tab will stop everything running in it, including the right drawer."))
    }
}
