import AppKit
import XCTest

@testable import TerminalKit

final class TerminalIdentityTests: XCTestCase {
    private final class Recorder: NSObject, TerminalSurfaceDelegate {
        var titles: [String] = []

        func surface(_ s: TerminalSurface, titleDidChange title: String) {
            titles.append(title)
        }
    }

    func test_theVersion_isOneClaudeReportsProgressTo() throws {
        let version = try XCTUnwrap(TerminalIdentity.environment["TERM_PROGRAM_VERSION"])
        let core = version.split(separator: "-").first.map(String.init) ?? ""
        let parts = core.split(separator: ".").compactMap { Int($0) }

        XCTAssertEqual(TerminalIdentity.environment["TERM_PROGRAM"], "ghostty")
        XCTAssertEqual(parts.count, 3, "\(version) is not a semantic version")
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 2, 0]), "Claude sends progress only from ghostty 1.2.0 on")
    }

    func test_theIdentity_isWhatALocalChildSees() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let recorder = Recorder()
        let surface = GhosttySurface()
        surface.delegate = recorder
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(
            TerminalSurfaceConfig(
                command: "/bin/sh",
                args: ["-c", #"printf '\033]0;%s|%s\007' "$TERM_PROGRAM" "$TERM_PROGRAM_VERSION"; sleep 100"#]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !recorder.titles.contains(where: { $0.contains("|") }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let program = try XCTUnwrap(TerminalIdentity.environment["TERM_PROGRAM"])
        let version = try XCTUnwrap(TerminalIdentity.environment["TERM_PROGRAM_VERSION"])
        XCTAssertFalse(version.isEmpty)
        XCTAssertEqual(recorder.titles.last { $0.contains("|") }, "\(program)|\(version)")
    }
}
