import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class PaneKeyPressTests: WindowTestCase {
    private var window: NSWindow!
    private var surface: GhosttySurface?

    override func setUpWithError() throws {
        try super.setUpWithError()
        KeyboardLayout.layoutOverrideForTesting = { _ in [0: "a", 8: "c", 49: " "] }
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
        KeyboardLayout.layoutOverrideForTesting = nil
        try super.tearDownWithError()
    }

    private func byteEcho() throws -> GhosttySurface {
        let surface = GhosttySurface()
        self.surface = surface
        let script = "stty raw -echo; echo READY; while :; do dd bs=1 count=1 2>/dev/null | od -An -tx1; done"
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", script]))
        try XCTSkipUnless(surface.isStarted, "ghostty_surface_new failed")
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        XCTAssertTrue(screen(of: surface) { $0.contains("READY") }.contains("READY"), "the echo never started")
        return surface
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

    private func bytes(_ lines: [String]) -> [String] {
        lines.drop { $0 != "READY" }.dropFirst().flatMap { $0.split(separator: " ").map(String.init) }
    }

    func test_namedKeysReachTheProgramAsTheBytesTheirKeystrokesSend() throws {
        let surface = try byteEcho()
        let pressed: [(String, [String])] = [
            ("enter", ["0d"]), ("escape", ["1b"]), ("up", ["1b", "5b", "41"]), ("down", ["1b", "5b", "42"]),
            ("left", ["1b", "5b", "44"]), ("right", ["1b", "5b", "43"]), ("ctrl-c", ["03"]), ("ctrl-a", ["01"]),
            ("tab", ["09"]), ("shift-tab", ["1b", "5b", "5a"]), ("backspace", ["7f"]), ("space", ["20"]),
            ("home", ["1b", "5b", "48"]), ("end", ["1b", "5b", "46"]), ("pageup", ["1b", "5b", "35", "7e"]),
            ("pagedown", ["1b", "5b", "36", "7e"]),
        ]
        for (name, _) in pressed {
            let key = try XCTUnwrap(PaneKey(name: name).flatMap(TerminalKey.init(paneKey:)), name)
            surface.press(key)
        }

        let expected = pressed.flatMap(\.1)
        let echoed = bytes(screen(of: surface) { self.bytes($0).count >= expected.count })

        XCTAssertEqual(echoed, expected)
    }
}
