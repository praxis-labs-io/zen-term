import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowControllerAppGlobalDispatchTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        super.tearDown()
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        return controller
    }

    func test_appGlobalChords_forwardToTheSeam() {
        let controller = makeController()
        var forwarded: [KeyInterceptor.ReservedChord] = []
        controller.onAppGlobalCommand = { forwarded.append($0) }

        controller.handle(.reloadConfig)
        controller.handle(.checkForUpdates)

        XCTAssertEqual(
            forwarded, [.reloadConfig, .checkForUpdates],
            "app-global chords from the palette must reach AppDelegate.route, not a no-op break")
    }

    func test_windowScopedChord_doesNotForward() {
        let controller = makeController()
        var forwarded: [KeyInterceptor.ReservedChord] = []
        controller.onAppGlobalCommand = { forwarded.append($0) }

        controller.handle(.toggleBottomDrawer)

        XCTAssertTrue(forwarded.isEmpty, "a window-scoped chord must not be forwarded to route")
    }
}
