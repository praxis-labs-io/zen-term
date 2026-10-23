import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class WindowPresentationTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    // Asserts `isVisible`: xctest runs `.prohibited`, so `isKeyWindow` reads false even with the bug in place.
    func test_mountAndStartLeavesTheWindowOffScreen() {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller

        controller.mountAndStart()

        XCTAssertFalse(
            controller.window.isVisible,
            "a mounted window landed on screen, so a test run scatters windows and steals focus")
    }

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
