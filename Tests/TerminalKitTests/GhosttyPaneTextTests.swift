import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyPaneTextTests: XCTestCase {
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []

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
        for surface in surfaces {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        surfaces = []
        window.close()
        window = nil
        super.tearDown()
    }

    private func mounted(_ command: String, _ args: [String]) throws -> GhosttySurface {
        let surface = GhosttySurface()
        surfaces.append(surface)
        surface.start(TerminalSurfaceConfig(command: command, args: args))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        return surface
    }

    private func lines(of surface: GhosttySurface, until done: ([String]) -> Bool) -> [String] {
        let deadline = Date().addingTimeInterval(10)
        var lines: [String] = []
        while Date() < deadline {
            lines = surface.text(lastLines: 10_000)?.components(separatedBy: "\n") ?? []
            if done(lines) { return lines }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return lines
    }

    func test_aSubmittedMultiLinePasteRunsAsOneBlockAtAZshPrompt() throws {
        let surface = try mounted("/bin/zsh", ["-f"])
        let prompt = lines(of: surface) { $0.last?.hasSuffix("% ") == true }
        XCTAssertEqual(prompt.last?.hasSuffix("% "), true, "zsh never drew its prompt: \(prompt)")

        surface.paste("echo AA$((40+2))\necho BB$((40+3))")
        surface.submit()

        let screen = lines(of: surface) { $0.contains("BB43") }
        XCTAssertEqual(screen.filter { $0 == "AA42" }.count, 1, "\(screen)")
        XCTAssertEqual(screen.filter { $0 == "BB43" }.count, 1, "\(screen)")
        XCTAssertEqual(screen.filter { $0.contains("%") }.count, 2, "the block ran per line: \(screen)")
    }

    func test_theLastLinesReachIntoTheScrollbackAndDropTrailingBlanks() throws {
        let surface = try mounted("/bin/sh", ["-c", "seq 5000; printf '   \\n  \\n\\n'; sleep 100"])
        _ = lines(of: surface) { $0.contains("5000") }

        let tail = surface.text(lastLines: 100)?.components(separatedBy: "\n")

        XCTAssertEqual(tail, (4901...5000).map(String.init))
    }
}
