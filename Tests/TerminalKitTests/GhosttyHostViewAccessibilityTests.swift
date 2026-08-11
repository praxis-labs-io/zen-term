import AppKit
import XCTest

@testable import TerminalKit

/// VoiceOver reads the terminal through the NSAccessibility overrides on `GhosttyHostView`.
/// This is the silently-dead class: the app renders identically whether or not the
/// overrides exist, and xctest runs with the accessibility engine `.prohibited`
/// (docs/swift-conventions.md), so nothing here drives VoiceOver itself. Instead the overrides
/// are called directly — that proves the contract VoiceOver consumes, while the spoken
/// experience stays on the runbook.
///
/// The content test needs a real surface and PTY, because the value is assembled by
/// `ghostty_surface_read_text` from the live grid; a pointer-less view can only prove the
/// nil path.
final class GhosttyHostViewAccessibilityTests: XCTestCase {
    /// The identity half needs no PTY: these answers are constants of the view. If they are
    /// wrong, assistive tools never ask the content questions at all.
    func test_hostViewIsAnAccessibleTextArea() {
        let view = GhosttyHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityHelp(), "Terminal content area")
    }

    /// Without a live surface every content answer must be the empty/nil shape, not a crash.
    func test_pointerLessViewAnswersEmpty() {
        let view = GhosttyHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(view.accessibilityValue() as? String, "")
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), 0)
        XCTAssertNil(view.accessibilitySelectedText())
    }

    /// Assistive clients probe with `NSNotFound` and near-`Int.max` ranges. `NSMaxRange`
    /// wraps on those (C addition, no trap), which lets a `NSMaxRange <= length` bounds
    /// check pass and the bogus range reach `substring(with:)`, which raises. The answer
    /// has to be nil, not an exception.
    func test_stringForRangeToleratesHostileRanges() {
        let view = GhosttyHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertNil(view.accessibilityString(for: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(view.accessibilityString(for: NSRange(location: 1, length: Int.max)))
        XCTAssertNil(view.accessibilityAttributedString(for: NSRange(location: NSNotFound, length: 1)))
    }

    /// One real surface, several faces of the same contract: what the shell printed is what
    /// `accessibilityValue` exposes, and the range-parameterized API indexes into that same
    /// string. Asserted together because they share the one cached screen read — a mismatch
    /// between them is exactly the bug VoiceOver would trip over when navigating by range.
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
        // Two marked lines then sleep, so the grid holds still while we read it. The marker is
        // unlikely to collide with anything a default prompt prints.
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

        // Poll rather than sleep: the shell has to start first, and CI is slower than this
        // machine. The runloop also carries libghostty's callbacks. The 500ms
        // content cache just makes early polls stale; later polls refetch.
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

        // The range-parameterized reads must index into the same string the value returned.
        let nsContents = contents as NSString
        XCTAssertEqual(hostView.accessibilityNumberOfCharacters(), nsContents.length)
        XCTAssertEqual(hostView.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: nsContents.length))
        let markerRange = nsContents.range(of: "zen-a11y-second")
        XCTAssertEqual(hostView.accessibilityString(for: markerRange), "zen-a11y-second")

        // Line navigation: the second marker sits at least one newline past the first.
        let firstLine = hostView.accessibilityLine(for: nsContents.range(of: "zen-a11y-first").location)
        let secondLine = hostView.accessibilityLine(for: markerRange.location)
        XCTAssertGreaterThan(secondLine, firstLine)

        // The attributed variant carries the terminal's font, which is what lets VoiceOver
        // and Look Up render the text it reads.
        let attributed = try XCTUnwrap(hostView.accessibilityAttributedString(for: markerRange))
        XCTAssertNotNil(
            attributed.attribute(.font, at: 0, effectiveRange: nil),
            "the attributed accessibility string must carry the terminal font")
    }
}
