import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyForegroundProcessTests: XCTestCase {
    func test_theForegroundGroupIsTheRunningProgramsGroup() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("zen-fg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let surface = GhosttySurface()
        XCTAssertNil(surface.foregroundProcessGroupID, "a surface that has not started has no foreground")
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(
            TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 100"]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")

        var program: pid_t?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, program == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            program = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let pid = try XCTUnwrap(program, "the program never started")

        XCTAssertEqual(surface.foregroundProcessGroupID, getpgid(pid))
    }
}
