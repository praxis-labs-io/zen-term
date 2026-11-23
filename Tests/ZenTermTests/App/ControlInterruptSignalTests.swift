import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ControlInterruptSignalTests: WindowTestCase {
    private var window: NSWindow!
    private var surface: GhosttySurface?

    override func setUpWithError() throws {
        try super.setUpWithError()
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
    }

    override func tearDownWithError() throws {
        surface?.view.removeFromSuperview()
        surface?.terminate()
        surface = nil
        window.close()
        window = nil
        try super.tearDownWithError()
    }

    private func screen(of surface: GhosttySurface, until done: ([String]) -> Bool) -> [String] {
        let deadline = Date().addingTimeInterval(10)
        var lines: [String] = []
        while Date() < deadline {
            lines = surface.text(lastLines: 10_000)?.components(separatedBy: "\n") ?? []
            if done(lines) { return lines }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return lines
    }

    func test_theForegroundGroupOfARealTerminalReceivesSIGINTAndKeepsRunning() throws {
        let surface = GhosttySurface()
        self.surface = surface
        let script = "trap 'echo INTERRUPTED' INT; echo READY; while :; do sleep 0.2; echo TICK; done"
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", script]))
        try XCTSkipUnless(surface.isStarted, "ghostty_surface_new failed")
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        XCTAssertTrue(screen(of: surface) { $0.contains("TICK") }.contains("TICK"), "the loop never started")
        let group = try XCTUnwrap(surface.foregroundProcessGroupID)
        guard group != getpgrp() else { return XCTFail("a signal to the test's own group would end the test run") }

        XCTAssertTrue(ControlResponder.interrupt(group: group))

        let screen = screen(of: surface) { lines in
            lines.drop { $0 != "INTERRUPTED" }.contains("TICK")
        }
        XCTAssertTrue(screen.contains("INTERRUPTED"), "\(screen.suffix(5))")
        XCTAssertTrue(screen.drop { $0 != "INTERRUPTED" }.contains("TICK"), "the program stopped: \(screen.suffix(5))")
    }
}
