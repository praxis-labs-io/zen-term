import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyClipboardTests: XCTestCase {
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []
    private var savedClipboard: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
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
        NSPasteboard.general.writeObjects(savedClipboard)
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

    private func waitFor(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !done() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // The embedded NUL proves the write is decoded by its length, not read as a C string.
    func test_anOSC52WriteLandsOnThePasteboardWhole() throws {
        let payload = "zen-osc52\u{0}write"
        let encoded = Data(payload.utf8).base64EncodedString()
        NSPasteboard.general.clearContents()
        _ = try mounted("printf '\\033]52;c;\(encoded)\\007'; sleep 100")

        waitFor { NSPasteboard.general.string(forType: .string) == payload }

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), payload)
    }

    func test_anOSC52ReadAnswersTheProgramWithThePasteboardText() throws {
        let clipboard = "zen-osc52-read"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipboard, forType: .string)
        let surface = try mounted(
            "stty -echo -icanon min 0 time 10; printf '\\033]52;c;?\\007'; "
                + "r=$(dd bs=1 count=512 2>/dev/null); "
                + "printf 'GOT:%s:END\\n' \"$(printf '%s' \"$r\" | tr '\\033\\007' '<>')\"; sleep 100")

        var screen = ""
        waitFor {
            screen = surface.text(lastLines: 100) ?? ""
            return screen.contains(":END")
        }

        let encoded = Data(clipboard.utf8).base64EncodedString()
        XCTAssertTrue(screen.contains("GOT:<]52;c;\(encoded)<"), screen)
    }
}
