import AppKit
import XCTest

@testable import ZenTerm

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
