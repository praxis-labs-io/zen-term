import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyBusyTrackingTests: XCTestCase {
    private func runSleep(tracksBusy: Bool, in window: NSWindow) throws -> GhosttySurface {
        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 390, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"], tracksBusy: tracksBusy))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        return surface
    }

    func test_anUntrackedSessionNeverReadsBusy_whileItsTrackedTwinDoes() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let tracked = try runSleep(tracksBusy: true, in: window)
        let untracked = try runSleep(tracksBusy: false, in: window)
        defer {
            for surface in [tracked, untracked] {
                surface.view.removeFromSuperview()
                surface.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !tracked.isBusy {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(tracked.isBusy, "a program with no prompt marks reads busy, or this test proves nothing")
        XCTAssertFalse(untracked.isBusy, "a session that never emits prompt marks must not read busy")
    }
}
