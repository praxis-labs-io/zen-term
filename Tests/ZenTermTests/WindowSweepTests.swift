import AppKit
import XCTest

@testable import ZenTerm

/// The sweep that `WindowTestCase` runs is a teardown hook, and a teardown hook that stops firing
/// fails nothing: the suite goes back to leaking 69 windows and stays green. That is the exact
/// failure ZEN-312 was filed for, so the sweep gets a test that drives it directly rather than
/// relying on the hook.
final class WindowSweepTests: XCTestCase {
    func test_sweepClosesAWindowLeftOpen() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible, "precondition: the window is on screen before the sweep")

        WindowTestCase.closeAllWindows()

        XCTAssertFalse(window.isVisible, "the sweep must close a window the test left open")
    }

    /// The `isVisible` filter this replaced skipped 35 of 43 teardowns, because most suites mount
    /// their host in a window they never order front. Closing is also what fires
    /// `windowWillClose`, so skipping those windows skips a teardown chain, not just a surface.
    func test_sweepClosesAWindowThatWasNeverOrderedIn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertFalse(window.isVisible, "precondition: never ordered in, so never visible")
        let closed = expectation(description: "windowWillClose fired")
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in closed.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        WindowTestCase.closeAllWindows()

        wait(for: [closed], timeout: 1.0)
    }
}
