import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyClipboardTests: XCTestCase {
    private typealias ClipboardBackup = [[NSPasteboard.PasteboardType: Data]]
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []
    private var clipboardBackup: ClipboardBackup = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        clipboardBackup = saveClipboard(NSPasteboard.general)
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
        restoreClipboard(NSPasteboard.general, clipboardBackup)
        clipboardBackup = []
        super.tearDown()
    }

    private func saveClipboard(_ pb: NSPasteboard) -> ClipboardBackup {
        (pb.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { $0[$1] = item.data(forType: $1) }
        }
    }

    private func restoreClipboard(_ pb: NSPasteboard, _ backup: ClipboardBackup) {
        pb.writeObjects(
            backup.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            })
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

    func test_aProgramReadingTheClipboardGetsTextWithEmbeddedNullWhole() throws {
        let text = "null\0instead\0of\0space"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let reply = "]52;c;\(base64(text))"

        let surface = try mounted("printf '\\033]52;c;?\\007'; exec cat -v")
        let screen = screen(of: surface) { $0.contains(reply) }

        XCTAssertTrue(screen.contains(reply), "the reply lost bytes: \(screen)")
    }

    func test_aProgramReadingThePrimarySelectionIsToldItIsUnsupported() throws {
        let text = "zen-primary-must-not-leak"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let surface = try mounted(
            "printf '\\033]5522;type=read:loc=primary:id=abc;dGV4dC9wbGFpbg==\\033\\\\'; exec cat -v")
        let screen = screen(of: surface) { $0.contains("status=ENOSYS") }

        XCTAssertTrue(screen.contains("]5522;type=read:status=ENOSYS:id=abc"), "no ENOSYS reply: \(screen)")
        XCTAssertFalse(screen.contains(base64(text)), "the pasteboard text leaked: \(screen)")
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

    func test_theClipboardBackupRestoresEveryItemWithTypes() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        let a = NSPasteboardItem()
        a.setString("first-item", forType: .string)
        let testType = NSPasteboard.PasteboardType("test.data")
        let testData = Data([1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89])
        let b = NSPasteboardItem()
        b.setString("second-item", forType: .string)
        b.setData(testData, forType: testType)

        pb.writeObjects([a, b])
        XCTAssertEqual(pb.pasteboardItems?.count, 2)
        let backup = saveClipboard(pb)

        pb.clearContents()
        XCTAssertEqual(pb.pasteboardItems ?? [], [])
        restoreClipboard(pb, backup)
        XCTAssertEqual(pb.pasteboardItems?.count, 2)

        let first = pb.pasteboardItems?.first
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.string(forType: .string), "first-item")

        let second = pb.pasteboardItems?.last
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.string(forType: .string), "second-item")
        XCTAssertEqual(second?.data(forType: testType), testData)
    }
}
