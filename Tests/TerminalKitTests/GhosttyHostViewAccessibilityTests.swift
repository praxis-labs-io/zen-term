import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyHostViewAccessibilityTests: XCTestCase {
    func test_hostViewIsAnAccessibleTextArea() {
        let view = GhosttyHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityHelp(), "Terminal content area")
    }

    func test_pointerLessViewAnswersEmpty() {
        let view = GhosttyHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(view.accessibilityValue() as? String, "")
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), 0)
        XCTAssertNil(view.accessibilitySelectedText())
    }

    func test_stringForRangeToleratesHostileRanges() {
        let view = GhosttyHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertNil(view.accessibilityString(for: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(view.accessibilityString(for: NSRange(location: 1, length: Int.max)))
        XCTAssertNil(view.accessibilityAttributedString(for: NSRange(location: NSNotFound, length: 1)))
    }

    func test_screenContentsFlowThroughTheAccessibilityAPI() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(
            TerminalSurfaceConfig(
                command: "/bin/sh",
                args: ["-c", "printf 'zen-a11y-first\\nzen-a11y-second\\n'; sleep 100"]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        let hostView = try XCTUnwrap(surface.view as? GhosttyHostView)

        let deadline = Date().addingTimeInterval(30)
        var contents = ""
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            contents = (hostView.accessibilityValue() as? String) ?? ""
            if contents.contains("zen-a11y-second") { break }
        }
        XCTAssertTrue(
            contents.contains("zen-a11y-first"),
            "accessibilityValue never showed the shell's output; got \(contents.debugDescription)")

        let nsContents = contents as NSString
        XCTAssertEqual(hostView.accessibilityNumberOfCharacters(), nsContents.length)
        XCTAssertEqual(hostView.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: nsContents.length))
        let markerRange = nsContents.range(of: "zen-a11y-second")
        XCTAssertEqual(hostView.accessibilityString(for: markerRange), "zen-a11y-second")

        let firstLine = hostView.accessibilityLine(for: nsContents.range(of: "zen-a11y-first").location)
        let secondLine = hostView.accessibilityLine(for: markerRange.location)
        XCTAssertGreaterThan(secondLine, firstLine)

        let attributed = try XCTUnwrap(hostView.accessibilityAttributedString(for: markerRange))
        XCTAssertNotNil(
            attributed.attribute(.font, at: 0, effectiveRange: nil),
            "the attributed accessibility string must carry the terminal font")
    }
}
