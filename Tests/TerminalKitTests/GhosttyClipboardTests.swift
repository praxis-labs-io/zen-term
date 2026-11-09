import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyClipboardTests: XCTestCase {
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []
    private var savedClipboard: String?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedClipboard = NSPasteboard.general.string(forType: .string)
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
        NSPasteboard.general.clearContents()
        if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
        super.tearDown()
    }

    private func mounted(_ script: String) throws -> GhosttySurface {
        let surface = GhosttySurface()
        surfaces.append(surface)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", script]))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        return surface
    }

    private func screen(of surface: GhosttySurface, until done: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline {
            text = surface.text(lastLines: 10_000) ?? ""
            if done(text) { return text }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return text
    }

    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    func test_aProgramReadingTheClipboardGetsThePasteboardText() throws {
        let text = "zen-clipboard-read"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let reply = "]52;c;\(base64(text))"

        let surface = try mounted("printf '\\033]52;c;?\\007'; exec cat -v")
        let screen = screen(of: surface) { $0.contains(reply) }

        XCTAssertTrue(screen.contains(reply), "the program never received the clipboard: \(screen)")
    }

    func test_aProgramReadingTheClipboardGetsNonASCIITextWhole() throws {
        let text = "héllo ✓ wörld"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let reply = "]52;c;\(base64(text))"

        let surface = try mounted("printf '\\033]52;c;?\\007'; exec cat -v")
        let screen = screen(of: surface) { $0.contains(reply) }

        XCTAssertTrue(screen.contains(reply), "the reply lost bytes: \(screen)")
    }

    func test_aProgramWritingTheClipboardSetsThePasteboard() throws {
        let text = "héllo ✓ wörld"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("before", forType: .string)

        _ = try mounted("printf '\\033]52;c;\(base64(text))\\007'; sleep 100")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, NSPasteboard.general.string(forType: .string) != text {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }
}
