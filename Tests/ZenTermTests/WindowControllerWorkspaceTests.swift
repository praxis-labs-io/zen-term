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

    func test_emptyingTheLastWorkspace_closesTheWindow() {
        let c = makeWindow()
        var closed = false
        c.onClosed = { closed = true }

        c.closeTabForTesting(index: 0)

        XCTAssertTrue(closed)
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

    private func press(
        _ key: String, typing characters: String, keyCode: UInt16, in c: WindowController
    ) throws {
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

    func test_cmdCtrlDigit_selectsBySidebarOrder_andTheWorkspaceLeftBehindKeepsRunning() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        let before = try surface(of: c, tab: home)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        _ = c.addWorkspaceForTesting(name: "Third", folder: root)

        try press("2", typing: "2", keyCode: 19, in: c)

        XCTAssertEqual(c.activeWorkspaceIDForTesting, second)
        XCTAssertNil(
            try XCTUnwrap(c.controllerForTesting(tab: home)).view.superview, "the background workspace is detached")
        XCTAssertFalse(before.terminated)

        try press("1", typing: "1", keyCode: 18, in: c)

        XCTAssertEqual(c.activeWorkspaceIDForTesting, first)
        let after = try surface(of: c, tab: home)
        XCTAssertTrue(before === after, "the same surface, so the same scrollback and process")
        XCTAssertEqual(after.startCount, 1)
        XCTAssertFalse(after.terminated)
    }

    func test_cmdCtrlDigit_pastTheLastWorkspace_doesNothing() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        _ = c.addWorkspaceForTesting(name: "Other", folder: root)

        try press("9", typing: "9", keyCode: 25, in: c)

        XCTAssertEqual(c.activeWorkspaceIDForTesting, first)
    }

    func test_cmdCtrlBrackets_cycleThroughWorkspaces_andWrap() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        let third = c.addWorkspaceForTesting(name: "Third", folder: root)

        try press("[", typing: "\u{1b}", keyCode: 33, in: c)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, third, "previous from the first wraps to the last")

        try press("]", typing: "\u{1d}", keyCode: 30, in: c)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, first, "next from the last wraps to the first")

        try press("]", typing: "\u{1d}", keyCode: 30, in: c)
        XCTAssertEqual(c.activeWorkspaceIDForTesting, second)
    }

    private func texts(in card: ToastView) -> [String] {
        descendants(of: card).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func keycaps(in card: ToastView) -> [String] {
        descendants(of: card).compactMap { ($0 as? KeycapView)?.shortcut }
    }

    func test_withOneWorkspace_aCardIsTitledByItsTabAlone() throws {
        let c = makeWindow()
        c.newTabForTesting()
        let first = try XCTUnwrap(c.tabOrderForTesting.first)

        c.notifyAgentForTesting(tab: first, message: "needs you")
        drainMainQueue()

        let card = try XCTUnwrap(c.waitingToastForTesting(tab: first))
        XCTAssertFalse(texts(in: card).contains { $0.hasPrefix("Workspace 1: ") })
    }

    func test_aBackgroundWorkspacesCard_namesItsWorkspace_andShowsTheWorkspaceShortcut() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(second)

        c.notifyAgentForTesting(tab: home, message: "needs you")
        drainMainQueue()

        let card = try XCTUnwrap(c.waitingToastForTesting(tab: home))
        XCTAssertTrue(texts(in: card).contains { $0.hasPrefix("Workspace 1: ") }, "the card says which workspace asked")
        XCTAssertEqual(keycaps(in: card), ["⌘⌃1"], "Switch reaches it by the workspace's shortcut")
    }

    func test_aBackgroundTabThatIsNotItsWorkspacesActiveOne_showsNoKeycap() throws {
        let c = makeWindow()
        let first = c.activeWorkspaceIDForTesting
        let home = try XCTUnwrap(c.tabIDsForTesting(workspace: first).first)
        c.newTabForTesting()
        let second = c.addWorkspaceForTesting(name: "Other", folder: root)
        c.activateWorkspaceForTesting(second)

        c.notifyAgentForTesting(tab: home, message: "needs you")
        drainMainQueue()

        let card = try XCTUnwrap(c.waitingToastForTesting(tab: home))
        XCTAssertEqual(keycaps(in: card), [], "⌘⌃1 would land on the other tab, so it isn't offered")
    }

    func test_aCardRaisedWithOneWorkspace_gainsItsWorkspaceName_whenASecondOpens() throws {
        let c = makeWindow()
        let home = try XCTUnwrap(c.activeTabIDForTesting)
        c.newTabForTesting()
        c.notifyAgentForTesting(tab: home, message: "needs you")
        drainMainQueue()
        let card = try XCTUnwrap(c.waitingToastForTesting(tab: home))
        XCTAssertFalse(texts(in: card).contains { $0.hasPrefix("Workspace 1: ") })

        c.openWorkspaceForTesting(
            Workspace(title: "Other", path: root, main: nil, right: nil, bottom: nil, focus: .main, env: [:]))

        XCTAssertTrue(
            texts(in: card).contains { $0.hasPrefix("Workspace 1: ") }, "the card now says which workspace asked")

        c.closeTabForTesting(tab: try XCTUnwrap(c.activeTabIDForTesting))

        XCTAssertEqual(c.workspaceIDsForTesting.count, 1)
        XCTAssertFalse(
            texts(in: card).contains { $0.hasPrefix("Workspace 1: ") }, "back to one workspace, the prefix goes")
    }

    func test_closingTheActiveWorkspace_landsOnTheOneAfterIt() throws {
        let c = makeWindow()
        let second = c.addWorkspaceForTesting(name: "Second", folder: root)
        let third = c.addWorkspaceForTesting(name: "Third", folder: root)
        c.activateWorkspaceForTesting(second)

        c.closeTabForTesting(tab: try XCTUnwrap(c.tabIDsForTesting(workspace: second).first))

        XCTAssertEqual(c.activeWorkspaceIDForTesting, third, "the neighbour, the way closing a tab lands")
    }

    func test_closingTheLastWorkspaceInOrder_landsOnTheOneBeforeIt() throws {
        let c = makeWindow()
        let second = c.addWorkspaceForTesting(name: "Second", folder: root)
        let third = c.addWorkspaceForTesting(name: "Third", folder: root)
        c.activateWorkspaceForTesting(third)

        c.closeTabForTesting(tab: try XCTUnwrap(c.tabIDsForTesting(workspace: third).first))

        XCTAssertEqual(c.activeWorkspaceIDForTesting, second)
    }

    func test_closingABackgroundWorkspace_leavesTheActiveOne() throws {
        let c = makeWindow()
        let second = c.addWorkspaceForTesting(name: "Second", folder: root)
        let third = c.addWorkspaceForTesting(name: "Third", folder: root)
        c.activateWorkspaceForTesting(third)

        c.closeTabForTesting(tab: try XCTUnwrap(c.tabIDsForTesting(workspace: second).first))

        XCTAssertEqual(c.activeWorkspaceIDForTesting, third)
        XCTAssertEqual(c.workspaceIDsForTesting.count, 2)
    }
}
