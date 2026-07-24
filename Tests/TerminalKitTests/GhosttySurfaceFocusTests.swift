import AppKit
import XCTest

@testable import TerminalKit

/// The focus libghostty is told about is `paneFocused && isAppActive`, and app activation is
/// half of that pair (ZEN-271). It has to be tested through the real notification, because the
/// bug was never in the combination — it was that nothing delivered the app half at all, so a
/// backgrounded pane kept a focused surface and ghostty kept its custom-shader draw timer
/// running at 120fps against a window nobody could see.
///
/// No `start()` here: these surfaces stay pointer-less on purpose, so the test covers the
/// wiring without a Metal layer or a PTY (the real-surface harness is env-gated for that
/// reason). `syncFocus` no-ops its libghostty call against a nil surface and still tracks state.
final class GhosttySurfaceFocusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Tearing a surface down reaches SecureInput, which reads `NSApp.isActive` through an
        // implicitly-unwrapped global. Without an application instance in the test process that
        // is a nil-unwrap crash, not a failure.
        _ = NSApplication.shared
    }

    /// Post the real notification, then give the main queue a turn before returning.
    /// `observeAppActive` registers with `queue: .main`, so delivery is an enqueued operation
    /// rather than a guaranteed same-turn call. Asserting straight after the post would ride on
    /// that timing and could go green or flaky for reasons unrelated to the focus logic.
    private func postAppActive(_ active: Bool) {
        NotificationCenter.default.post(
            name: active
                ? NSApplication.didBecomeActiveNotification
                : NSApplication.didResignActiveNotification,
            object: NSApp)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func test_appDeactivationUnfocusesAFocusedPane() {
        let surface = GhosttySurface()
        surface.setFocused(true)
        XCTAssertTrue(surface.lastFocused, "a focused pane in an active app is focused")

        postAppActive(false)
        XCTAssertFalse(surface.lastFocused, "switching apps has to unfocus the surface")

        postAppActive(true)
        XCTAssertTrue(surface.lastFocused, "coming back restores the pane that had focus")
    }

    /// The pane half has to survive the app half moving under it — an unfocused pane must not
    /// come back focused just because the app did, or every pane in the window would animate.
    func test_appActivationDoesNotFocusAnUnfocusedPane() {
        let surface = GhosttySurface()
        surface.setFocused(false)

        postAppActive(false)
        XCTAssertFalse(surface.lastFocused)

        postAppActive(true)
        XCTAssertFalse(surface.lastFocused, "an unfocused pane stays unfocused when the app returns")
    }

    /// Focusing a pane while the app is in the background must not start the draw timer: the
    /// chrome re-sends focus state on its own schedule, and a background app is still background.
    func test_focusingAPaneWhileTheAppIsInactiveKeepsTheSurfaceUnfocused() {
        let surface = GhosttySurface()
        postAppActive(false)

        surface.setFocused(true)
        XCTAssertFalse(surface.lastFocused, "pane focus alone can't focus a surface in a background app")

        postAppActive(true)
        XCTAssertTrue(surface.lastFocused, "and it takes effect once the app is frontmost")
    }

    /// A surface torn down mid-session must stop hearing about activation — a late callback
    /// against a freed libghostty pointer is the crash this guards.
    func test_terminateStopsTrackingAppActivation() {
        let surface = GhosttySurface()
        surface.setFocused(true)
        surface.terminate()

        postAppActive(false)
        XCTAssertTrue(surface.lastFocused, "a terminated surface no longer follows activation")
    }
}
