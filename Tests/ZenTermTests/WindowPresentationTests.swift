import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Presenting a window is the caller's job, not `mountAndStart()`'s. A window suite mounts real
/// `WindowController`s, and while `mountAndStart()` ordered its own window in, a local `swift test`
/// run peaked at 80 windows on screen and took key from whatever was being typed in, once per test.
/// The interaction tests still drive a real window; the ones that need key take it themselves.
final class WindowPresentationTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        // `WindowController` reads config at construction (backdrop alpha, hidden toolbar buttons,
        // window chrome), and unpinned that is the developer's own `~/.config/zen-term/config`.
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        // The real ghostty backend needs a live libghostty app, which a test bundle has no
        // business spinning up.
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    /// Asserts on `isVisible`, not `isKeyWindow`. `xctest` runs `.prohibited`, so a window it orders
    /// in never registers as key even while the window server is raising it over the developer's
    /// editor: `isKeyWindow` reads false with the bug reinstated, and the assertion could never
    /// fail. Ordering is the observable half, and it is the half that scatters windows and pulls
    /// focus.
    func test_mountAndStartLeavesTheWindowOffScreen() {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller

        controller.mountAndStart()

        XCTAssertFalse(
            controller.window.isVisible,
            "a mounted window landed on screen, so a test run scatters windows and steals focus")
    }

    /// The point of not presenting is that everything else still happened: the first tab is built
    /// and its shell started, so a suite drives the same controller it always did.
    func test_mountAndStartStillBuildsAndStartsTheFirstTab() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller

        controller.mountAndStart()

        let surface = try XCTUnwrap(
            controller.anyTerminalSurface, "the first tab's surface must exist after mountAndStart")
        XCTAssertNotNil(surface.view.window, "the first tab must be mounted in the window")
    }
}
