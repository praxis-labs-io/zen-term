import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowKeyFocusTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []

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
        XCTAssertNotEqual(pane.focusRenders.last, false, "precondition: the pane starts focused")

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
