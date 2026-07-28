import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The command palette dispatches a picked command through `WindowController.handle(_:)`, but the
/// app-global chords (reload config, check for updates) are owned by `AppDelegate.route`, not the
/// window. `handle` forwards them via `onAppGlobalCommand`; without that seam a palette pick is a
/// silent no-op — which is exactly how "Reload Config" from the palette shipped doing nothing
/// (ZEN-20). This pins the forwarding so it can't regress to a bare `break` again.
@MainActor
final class WindowControllerAppGlobalDispatchTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        // A real ghostty surface needs a live libghostty app; inject a headless stub instead.
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
        // Only the app-global arm calls the seam; a window-scoped action is handled in place, so the
        // forward must stay specific rather than firing for every chord.
        let controller = makeController()
        var forwarded: [KeyInterceptor.ReservedChord] = []
        controller.onAppGlobalCommand = { forwarded.append($0) }

        controller.handle(.toggleBottomDrawer)

        XCTAssertTrue(forwarded.isEmpty, "a window-scoped chord must not be forwarded to route")
    }
}
