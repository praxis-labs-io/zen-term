import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowKeyFocusTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controllers = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func resignKey(_ c: WindowController) {
        c.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    }

    private func becomeKey(_ c: WindowController) {
        c.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    }

    func test_anotherWindowTakingKey_blursTheFocusedPaneBelowTheSeam() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        XCTAssertEqual(pane.focusRenders.last, true, "precondition: the pane starts focused")

        resignKey(c)

        XCTAssertEqual(pane.focusRenders.last, false, "libghostty is told the pane lost focus")

        becomeKey(c)

        XCTAssertEqual(pane.focusRenders.last, true, "and told again when the window comes back")
    }

    func test_aFocusedDrawer_losesFocusWithItsWindow() throws {
        let c = makeWindow()
        c.handle(.toggleRightDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let drawer = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        XCTAssertEqual(drawer.focusRenders.last, true, "precondition: the drawer holds focus")

        resignKey(c)

        XCTAssertEqual(drawer.focusRenders.last, false)

        becomeKey(c)

        XCTAssertEqual(drawer.focusRenders.last, true)
    }

    func test_aFocusedDrawer_dropsItsHaloWithItsWindow() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(c.focusedPanelForTesting)
        XCTAssertGreaterThan(panel.haloOpacityForTesting, 0, "precondition: the drawer shows its halo")

        resignKey(c)

        XCTAssertEqual(panel.haloOpacityForTesting, 0)

        becomeKey(c)

        XCTAssertGreaterThan(panel.haloOpacityForTesting, 0)
    }

    func test_aTabLeftBehind_readsUnfocused_andComesBackWhenItIsActiveAgain() throws {
        let c = makeWindow()
        let first = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)

        c.handle(.newTab)
        c.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(first.focusRenders.last, false, "only the active tab's pane reports focused")
        let second = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        XCTAssertEqual(second.focusRenders.last, true)

        resignKey(c)
        becomeKey(c)

        XCTAssertEqual(first.focusRenders.last, false, "a background tab stays unfocused across a key cycle")

        c.selectTabForTesting(index: 0)
        c.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(first.focusRenders.last, true, "and gets its cursor back when you return to it")
        XCTAssertEqual(second.focusRenders.last, false)
    }

    func test_revealingTheSidebar_leavesAModeHoldingTheDrawerUnfocused() throws {
        let c = makeWindow()
        c.handle(.toggleRightDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let drawer = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        c.handle(.toggleScrollMode)
        XCTAssertEqual(drawer.focusRenders.last, false, "precondition: the mode renders the drawer unfocused")

        c.sidebarForTesting.focusActiveRow()

        XCTAssertEqual(
            drawer.focusRenders.last, false, "the sidebar taking focus does not hand the drawer back its cursor")
    }

    func test_aModeEndingWhenFocusMovesToADrawer_givesThePaneItsCursorBack() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        c.handle(.toggleScrollMode)
        XCTAssertEqual(pane.focusRenders.last, false, "precondition: the mode blurs the pane")

        c.handle(.toggleRightDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()
        c.handle(.toggleRightDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            pane.focusRenders.last, true,
            "the mode ended while the drawer held focus, and the pane's render flag has to come back with it")
    }

    func test_aPaneSurvivingAnExitWhileADrawerHoldsFocus_takesTheKeyboardAndReportsFocused() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let dying = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        c.handle(.toggleRightDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()

        dying.delegate?.surfaceDidExit(dying, code: 0)
        c.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            pane.focusRenders.last, true,
            "the surviving pane took first responder, so it cannot be left reporting unfocused")
    }

    func test_aDrawerOpenedInANonKeyWindow_doesNotReportFocused() throws {
        let c = makeWindow()
        resignKey(c)

        c.handle(.toggleRightDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()

        let drawer = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        XCTAssertEqual(
            drawer.focusRenders.last, false,
            "taking first responder tells libghostty focused, so the gate has to run after it")
    }

    func test_aModeEndingWhileTheWindowIsNotKey_doesNotHandTheCursorBack() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(c.focusedSurfaceForTesting as? RecordingSurface)
        resignKey(c)
        XCTAssertEqual(pane.focusRenders.last, false, "precondition: the window lost key")

        c.handle(.toggleScrollMode)
        c.handle(.toggleScrollMode)

        XCTAssertEqual(
            pane.focusRenders.last, false, "the window is still not key, whatever the mode released")
    }
}
