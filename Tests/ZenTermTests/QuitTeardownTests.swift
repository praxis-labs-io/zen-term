import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Quitting must terminate every surface. `windowWillClose` does not fire on app termination,
/// so the window's teardown has to be driven explicitly or every shell is orphaned.
final class QuitTeardownTests: WindowTestCase {
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

    /// The half that actually changed. `tearDownForQuit` is a thin alias for the teardown the
    /// close button already drove, so the two tests above pass with or without this fix: what
    /// was broken is that NOTHING called it on the quit path. This drives that path, and waits
    /// on the sweep the way the real quit does.
    func test_quitTeardownTerminatesEverySurfaceThenCompletesOnce() {
        let delegate = AppDelegate()
        delegate.addWindowForTesting()
        XCTAssertFalse(spawned.isEmpty, "no surface was created")
        XCTAssertFalse(spawned.contains { $0.terminated }, "surfaces died before the quit")

        var completions = 0
        let done = expectation(description: "quit teardown completed")
        delegate.quitTeardownForTesting {
            completions += 1
            if completions == 1 { done.fulfill() }
        }
        wait(for: [done], timeout: 10)

        XCTAssertTrue(spawned.allSatisfy { $0.terminated }, "quit left surfaces running")

        // The reply must land exactly once: `.terminateLater` treats two as a crash and none as
        // a quit that hangs forever. Wait past the cap so a second fire would have arrived.
        let settled = expectation(description: "past the drain cap")
        DispatchQueue.main.asyncAfter(deadline: .now() + ShellSessionReaper.quitSweepBudget + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 10)
        XCTAssertEqual(completions, 1, "quit must complete exactly once")
    }

    /// Closing the last window terminates the app without a confirm, and `windows` is already
    /// empty by then. That path used to answer `.terminateNow` and exit while the sweep from
    /// `windowWillClose` was still waiting for the leader to go, so nothing was ever signalled.
    func test_terminatingWithNoWindowsStillWaitsForTheSweep() {
        let delegate = AppDelegate()
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApp), .terminateLater,
            "quit with no windows must wait for the in-flight sweep, not exit immediately")
        // Nothing replied to a request AppKit never made, so let the pending reply resolve.
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    func test_tearDownForQuitIsIdempotentWithTheCloseButton() {
        let c = makeController()
        c.tearDownForQuit()
        // A native close landing after the quit teardown must not trap or double-fire.
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(spawned.allSatisfy { $0.terminated })
    }
}
