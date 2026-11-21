import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyProgramStatusTests: XCTestCase {
    func test_supportQueryIsAnswered() throws {
        let reply = try runInSurface(
            ["stty raw -echo", "printf '\\033]7501;?\\007'", "dd bs=1 count=8 2>/dev/null > \"$OUT\""],
            until: { $0.count >= 8 })
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "\u{1b}]7501;?")
    }

    private func runInSurface(
        _ lines: [String], delegate: TerminalSurfaceDelegate? = nil, until done: (Data) -> Bool
    ) throws -> Data {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let stem = NSTemporaryDirectory() + "zen7501-\(UUID().uuidString)"
        let output = "\(stem)-out"
        let script = "\(stem).sh"
        defer {
            try? FileManager.default.removeItem(atPath: output)
            try? FileManager.default.removeItem(atPath: script)
        }
        try (["OUT='\(output)'"] + lines).joined(separator: "\n").write(
            toFile: script, atomically: true, encoding: .utf8)

        let surface = GhosttySurface()
        surface.delegate = delegate
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: [script]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")

        let deadline = Date().addingTimeInterval(10)
        var data = Data()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            data = FileManager.default.contents(atPath: output) ?? Data()
            if done(data) { return data }
        }
        XCTFail("the surface did not finish within 10s; got \(String(decoding: data, as: UTF8.self).debugDescription)")
        return data
    }
}
