import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowControllerWorkspaceTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        c.mountAndStart()
        controller = c
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

    private func pressSwitch(on card: ToastView) throws {
        let button = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == "Switch" })
        button.performClick(nil)
    }

    private func surface(of c: WindowController, tab: TabID) throws -> RecordingSurface {
        let controller = try XCTUnwrap(c.controllerForTesting(tab: tab))
        return try XCTUnwrap(controller.allSurfaces.first as? RecordingSurface)
    }

    func test_everyWindowStartsWithOneWorkspace() {
        let c = makeWindow()

        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting[0])
    }

    func test_tabIDsDoNotCollideAcrossWorkspaces() {
        let c = makeWindow()
        c.newTabForTesting()

        let second = c.addWorkspaceForTesting(name: "Other", folder: root)

        let all = c.workspaceIDsForTesting.flatMap { c.tabIDsForTesting(workspace: $0) }
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(c.tabIDsForTesting(workspace: second).count, 1)
    }

    func test_switchingAwayAndBack_keepsTheSameRunningSurface() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        let before = try surface(of: c, tab: home)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)

        c.activateWorkspaceForTesting(second)
        c.activateWorkspaceForTesting(first)

        let after = try surface(of: c, tab: home)
        XCTAssertTrue(before === after)
        XCTAssertEqual(after.startCount, 1)
    }

    func test_anInactiveWorkspaceIsDetached_notHidden() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)

        c.activateWorkspaceForTesting(second)

        let view = try XCTUnwrap(c.controllerForTesting(tab: home)).view
        XCTAssertNil(view.superview)
        XCTAssertFalse(view.isHidden)
    }

    func test_anAgentInABackgroundWorkspace_stillAsksTheWindow() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(second)

        c.notifyAgentForTesting(tab: home, message: "needs you")
        drainMainQueue()

        XCTAssertEqual(c.attentionStateForTesting(tab: home), .waiting)
        XCTAssertEqual(c.workspaceAttentionForTesting(first), .waiting)
        XCTAssertEqual(c.workspaceAttentionForTesting(second), .idle)
        XCTAssertEqual(c.windowAttentionForTesting, .waiting)
        XCTAssertEqual(AttentionCenter.shared.waiting.first { $0.windowID == c.windowID }?.count, 1)
    }

    func test_selectingATabInABackgroundWorkspace_activatesItsWorkspaceFirst() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(second)
        c.notifyAgentForTesting(tab: home, message: "needs you")
        drainMainQueue()

        c.selectTab(home)
        drainMainQueue()

        XCTAssertEqual(c.activeWorkspaceIDForTesting, first)
        XCTAssertEqual(c.activeTabIDForTesting, home)
        XCTAssertEqual(c.attentionStateForTesting(tab: home), .idle)
    }

    func test_emptyingTheActiveWorkspace_activatesAnotherRatherThanClosingTheWindow() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(second)
        var closed = false
        c.onClosed = { closed = true }

        c.closeTabs(atPath: root)

        XCTAssertFalse(closed)
        XCTAssertEqual(c.workspaceIDsForTesting, [first])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, first)
        XCTAssertEqual(c.activeTabIDForTesting, c.tabIDsForTesting(workspace: first).first)
    }

    func test_emptyingTheLastWorkspace_keepsTheWindow_andOpensAFreshOne() {
        let c = makeWindow()
        let before = c.activeWorkspaceIDForTesting
        var closed = false
        c.onClosed = { closed = true }

        c.closeTabForTesting(index: 0)

        XCTAssertFalse(closed, "a window never closes as a side effect of emptying a workspace")
        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
        XCTAssertNotEqual(c.activeWorkspaceIDForTesting, before)
        XCTAssertEqual(c.tabOrderForTesting.count, 1)
    }

    func test_tabCountAtPath_countsEveryWorkspace() {
        let c = makeWindow()

        _ = c.addWorkspaceForTesting(name: "Other", folder: root)

        XCTAssertEqual(c.tabCount(atPath: root), 1)
    }

    func test_closingTabsAtPath_reachesABackgroundWorkspace() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.newTabForTesting()
        XCTAssertEqual(c.tabIDsForTesting(workspace: second).count, 1)
        var closed = false
        c.onClosed = { closed = true }

        c.closeTabs(atPath: root)

        XCTAssertEqual(c.workspaceIDsForTesting, [first])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, first)
        XCTAssertFalse(closed)
    }

    func test_switchOnAPaneCard_reachesATabInABackgroundWorkspace() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(second)
        c.notifyAgentForTesting(tab: home, message: "needs you")
        drainMainQueue()
        let card = try XCTUnwrap(c.waitingToastForTesting(tab: home))

        try pressSwitch(on: card)
        drainMainQueue()

        XCTAssertEqual(c.activeWorkspaceIDForTesting, first)
        XCTAssertEqual(c.activeTabIDForTesting, home)
        XCTAssertEqual(c.attentionStateForTesting(tab: home), .idle)
    }

    func test_switchOnACompletionCard_reachesATabInABackgroundWorkspace() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(second)
        c.notifyCommandFinishedForTesting(
            tab: home, result: TerminalCommandResult(exitCode: 0, duration: 30))
        drainMainQueue()
        let card = try XCTUnwrap(c.waitingToastForTesting(tab: home))

        try pressSwitch(on: card)
        drainMainQueue()

        XCTAssertEqual(c.activeWorkspaceIDForTesting, first)
        XCTAssertEqual(c.activeTabIDForTesting, home)
    }

    func test_revealingATab_landsOnItWithoutShowingItsWorkspacesPreviousTab() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        c.newTabForTesting()
        let asking = try XCTUnwrap(c.activeTabIDForTesting)
        XCTAssertNotEqual(asking, home)
        c.selectTabForTesting(index: 0)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(second)
        c.notifyAgentForTesting(tab: asking, message: "needs you")
        drainMainQueue()
        c.notifyAgentForTesting(tab: home, message: "also needs you")
        drainMainQueue()

        c.selectTab(asking)
        drainMainQueue()

        XCTAssertEqual(c.activeTabIDForTesting, asking)
        XCTAssertEqual(
            c.attentionStateForTesting(tab: home), .waiting,
            "home was never on screen, so revealing its neighbour must not answer it")
    }

    func test_closingABackgroundWorkspacesTab_leavesTheVisibleFloatOpen() throws {
        let c = makeWindow()
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        let stray = try XCTUnwrap(c.tabIDsForTesting(workspace: second).first)
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        drainMainQueue()
        XCTAssertTrue(c.isToolFloatOpen)

        c.closeTabForTesting(tab: stray)
        drainMainQueue()

        XCTAssertTrue(c.isToolFloatOpen, "a tab closing out of sight must not shut the float on screen")
    }
}
