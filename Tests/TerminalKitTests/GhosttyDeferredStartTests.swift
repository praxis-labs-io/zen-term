import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyDeferredStartTests: XCTestCase {
    func test_aSurfaceMountedBeforeItStarts_takesFocusKeysAndLayout_thenStarts() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let first = GhosttySurface()
        first.view.frame = NSRect(x: 0, y: 0, width: 390, height: 560)
        window.contentView?.addSubview(first.view)
        first.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))
        defer {
            first.view.removeFromSuperview()
            first.terminate()
        }
        try XCTSkipIf(first.surfacePtr == nil, "ghostty_surface_new failed")

        let waiting = GhosttySurface()
        waiting.view.frame = NSRect(x: 400, y: 0, width: 390, height: 560)
        window.contentView?.addSubview(waiting.view)
        defer {
            waiting.view.removeFromSuperview()
            waiting.terminate()
        }
        waiting.focus()
        waiting.setFocused(true)
        waiting.view.frame = NSRect(x: 400, y: 0, width: 300, height: 400)
        waiting.view.layoutSubtreeIfNeeded()
        for keyCode: UInt16 in [0, 36, 53] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "a",
                    charactersIgnoringModifiers: "a", isARepeat: false, keyCode: keyCode))
            waiting.view.keyDown(with: event)
        }
        waiting.paste("text")
        XCTAssertFalse(waiting.isBusy)
        XCTAssertNil(waiting.cellMetrics)
        XCTAssertFalse(waiting.isStarted)

        waiting.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))

        XCTAssertNotNil(waiting.surfacePtr, "a surface laid out and typed into before it starts must still start")
        XCTAssertNotNil(waiting.cellMetrics, "a late start must size the grid to the view it is already in")
        XCTAssertTrue(waiting.isStarted)

        waiting.terminate()

        XCTAssertFalse(waiting.isStarted)
    }

    func test_aSurfaceTerminatedBeforeItStarts_neverStarts() {
        let surface = GhosttySurface()

        surface.terminate()
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))

        XCTAssertNil(surface.surfacePtr, "a held-back start for a pane closed meanwhile would run an orphaned session")
        XCTAssertFalse(surface.isStarted)
    }
}
