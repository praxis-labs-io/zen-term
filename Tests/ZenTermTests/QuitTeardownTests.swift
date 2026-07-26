import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Quitting must terminate every surface. `windowWillClose` does not fire on app termination,
/// so the window's teardown has to be driven explicitly or every shell is orphaned (ZEN-269).
final class QuitTeardownTests: XCTestCase {
    private var spawned: [RecordingSurface] = []
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        spawned = []
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
    }

    override func tearDown() {
        TerminalSurfaceFactory.makeOverride = nil
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        super.tearDown()
    }

    private func makeController() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), initialCWD: nil)
        controller = c
        c.showAndStart()
        return c
    }

    func test_tearDownForQuitTerminatesEverySurface() {
        let c = makeController()
        XCTAssertFalse(spawned.isEmpty, "no surface was created")
        XCTAssertFalse(spawned.contains { $0.terminated }, "surfaces died before the quit")

        c.tearDownForQuit()

        XCTAssertTrue(spawned.allSatisfy { $0.terminated }, "quit left surfaces running")
    }

    /// A drawer's shell is not on the pane canvas, and it is the case in the bug report: a dev
    /// server running in a drawer when the window went away.
    func test_tearDownForQuitTerminatesDrawerSurfaces() {
        let c = makeController()
        c.handle(.toggleBottomDrawer)
        XCTAssertGreaterThanOrEqual(spawned.count, 2, "drawer surface was never created")

        c.tearDownForQuit()

        XCTAssertTrue(spawned.allSatisfy { $0.terminated }, "quit left the drawer's shell running")
    }

    func test_tearDownForQuitIsIdempotentWithTheCloseButton() {
        let c = makeController()
        c.tearDownForQuit()
        // A native close landing after the quit teardown must not trap or double-fire.
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(spawned.allSatisfy { $0.terminated })
    }
}
