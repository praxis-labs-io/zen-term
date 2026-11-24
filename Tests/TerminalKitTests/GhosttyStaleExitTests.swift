import AppKit
import XCTest

@testable import TerminalKit

// A message queued for a freed surface must not reach a new surface libghostty puts at its address.
final class GhosttyStaleExitTests: XCTestCase {
    private final class Recorder: NSObject, TerminalSurfaceDelegate {
        var events: [String] = []

        func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult) {
            events.append("finished")
        }

        func surfaceDidExit(_ s: TerminalSurface, code: Int32?) { events.append("exited") }
    }

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
    }

    override func tearDown() {
        window.close()
        window = nil
        super.tearDown()
    }

    private func start(_ command: String, _ args: [String], recorder: Recorder) throws -> GhosttySurface {
        let surface = GhosttySurface()
        surface.delegate = recorder
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: command, args: args))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        return surface
    }

    private func close(_ surface: GhosttySurface) {
        surface.view.removeFromSuperview()
        surface.terminate()
    }

    func test_aFreedSurfacesQueuedExitNeverReachesANewSurfaceAtItsAddress() throws {
        var reused = 0
        for _ in 0..<40 where reused < 3 {
            let exited = try start("/usr/bin/true", [], recorder: Recorder())
            let freedAddress = exited.surfacePtr
            Thread.sleep(forTimeInterval: 0.3)
            close(exited)

            let recorder = Recorder()
            let successor = try start("/bin/sleep", ["100"], recorder: recorder)
            defer { close(successor) }
            guard successor.surfacePtr == freedAddress else { continue }
            reused += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(recorder.events, [])
        }
        try XCTSkipIf(reused == 0, "libghostty never reused a freed surface's address, so nothing was checked")
    }
}
