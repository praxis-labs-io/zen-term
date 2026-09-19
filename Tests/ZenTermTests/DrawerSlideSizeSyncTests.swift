import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class DrawerSlideSizeSyncTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?
    private var surfaces: [RecordingSurface] = []

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { false }
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.surfaces.append(surface)
            return surface
        }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        super.tearDown()
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        return controller
    }

    func test_drawerSlide_holdsThePaneGridUntilItLands() throws {
        let controller = makeController()
        let pane = try XCTUnwrap(surfaces.first)

        controller.handle(.toggleBottomDrawer)

        XCTAssertEqual(pane.sizeSyncHolds, 1, "the pane's grid is held while the drawer slides")
        waitUntil(pane.sizeSyncHolds == 0, "the hold to release once the slide lands, so the grid reflows once")
    }
}
