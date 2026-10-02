import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class BackgroundTabTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        controller = c
        return c
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func tabBar(of c: WindowController) throws -> TabBarView {
        try XCTUnwrap(descendants(of: c.containerForTesting).compactMap { $0 as? TabBarView }.first)
    }

    private func openBackgroundTab(in c: WindowController, command: String? = nil) throws -> TabID {
        try XCTUnwrap(c.openTab(in: c.activeWorkspaceID, cwd: nil, command: command))
    }

    func test_aBackgroundTabJoinsTheTabBarWithoutBecomingActive() throws {
        let c = makeWindow()
        let active = try XCTUnwrap(c.activeTabIDForTesting)

        let id = try openBackgroundTab(in: c, command: "npm run dev")

        XCTAssertEqual(c.activeTabIDForTesting, active)
        XCTAssertEqual(c.tabOrderForTesting, [active, id])
        XCTAssertEqual(try tabBar(of: c).chipsForTesting.count, 2, "the new tab's number is in the tab bar")
        let surface = try XCTUnwrap(spawned.last)
        XCTAssertNil(surface.view.window, "a background tab is not mounted")
        XCTAssertTrue(
            surface.lastConfig?.args.last?.contains("npm run dev") == true, "the tab's pane runs the command")
    }

    func test_aBackgroundTabIsLaidOutAtTheCanvasSizeBeforeItIsShown() throws {
        let c = makeWindow()
        let showing = try XCTUnwrap(spawned.first)
        XCTAssertGreaterThan(showing.view.bounds.width, 0)

        _ = try openBackgroundTab(in: c)

        let background = try XCTUnwrap(spawned.last)
        XCTAssertNil(background.view.window)
        XCTAssertEqual(background.view.bounds.size, showing.view.bounds.size)
        XCTAssertEqual(background.lastConfig?.backingScale, c.window.backingScaleFactor)
    }

    func test_theAttentionStoreTreatsABackgroundTabAsNotSeen() throws {
        let c = makeWindow()
        let showing = try XCTUnwrap(c.activeTabIDForTesting)
        let id = try openBackgroundTab(in: c)

        c.notifyAgentForTesting(tab: id, message: "Claude needs your permission")
        c.notifyAgentForTesting(tab: showing, message: "Claude needs your permission")
        drainMainQueue()

        XCTAssertEqual(c.attentionStateForTesting(tab: id), .waiting)
        XCTAssertNotNil(c.waitingToastForTesting(tab: id), "an unseen ask raises its card")
        XCTAssertNil(c.waitingToastForTesting(tab: showing), "the tab on screen was seen asking")
    }

    func test_openingABackgroundTabLeavesSettingsUp() throws {
        let c = makeWindow()
        c.handle(.openSettings)
        XCTAssertTrue(c.isModalOverlayOpen)

        _ = try openBackgroundTab(in: c)

        XCTAssertTrue(c.isModalOverlayOpen)
    }

    func test_openingABackgroundTabLeavesAConfirmUp() throws {
        let c = makeWindow()
        c.presentConfirm(variant: .warning, title: "Close Tab", message: "", confirmLabel: "Close") {}

        _ = try openBackgroundTab(in: c)

        XCTAssertTrue(c.isConfirmOpen, "the background tab's first focus is not the user's")
    }

    func test_theNewTabChordStillShowsTheTabItOpens() throws {
        let c = makeWindow()

        c.newTabForTesting()

        let surface = try XCTUnwrap(spawned.last)
        XCTAssertEqual(c.activeTabIDForTesting, c.tabOrderForTesting.last)
        XCTAssertNotNil(surface.view.window)
    }

    func test_aBackgroundWorkspaceOpensWithItsRecipeWithoutSwitching() throws {
        let c = makeWindow()
        let showing = c.activeWorkspaceIDForTesting
        let ws = Workspace(
            title: "alpha", path: FileManager.default.temporaryDirectory,
            tabs: [Workspace.Tab(name: "one"), Workspace.Tab(name: "two", bottom: "shell")],
            focus: Workspace.LaunchFocus(tab: 1, region: .main), env: [:])

        let id = c.openConfiguredWorkspace(ws)

        XCTAssertEqual(c.activeWorkspaceIDForTesting, showing)
        let tabs = c.tabIDsForTesting(workspace: id)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(c.activeTab(of: id), tabs[1], "the launch focus is selected")
        XCTAssertEqual(c.controllerForTesting(tab: tabs[1])?.overlayState.isBottomOpen, true)
        XCTAssertTrue(spawned.dropFirst().allSatisfy { $0.view.window == nil })
    }

    func test_removingABackgroundTabLeavesAConfirmUp() throws {
        let c = makeWindow()
        let id = try openBackgroundTab(in: c)
        c.presentConfirm(variant: .warning, title: "Close Tab", message: "", confirmLabel: "Close") {}

        c.removeTab(id)

        XCTAssertEqual(c.tabOrderForTesting.count, 1)
        XCTAssertTrue(c.isConfirmOpen)
    }

    func test_removingTheShowingTabLeavesSettingsUpAndShowsItsNeighbour() throws {
        let c = makeWindow()
        let showing = try XCTUnwrap(c.activeTabIDForTesting)
        let neighbour = try openBackgroundTab(in: c)
        c.handle(.openSettings)

        c.removeTab(showing)

        XCTAssertEqual(c.activeTabIDForTesting, neighbour)
        XCTAssertNotNil(spawned.last?.view.window)
        XCTAssertTrue(c.isModalOverlayOpen)
    }
}
