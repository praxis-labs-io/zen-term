import AppKit
import XCTest

@testable import TerminalKit

// Proves the OSC 133 marks a `-c` wrapper emits actually reach `commandDidFinish`.
final class GhosttyProgramExitMarkTests: XCTestCase {
    private final class Recorder: NSObject, TerminalSurfaceDelegate {
        var results: [TerminalCommandResult] = []

        func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult) {
            results.append(result)
        }
    }

    private func runWrapper(_ script: String, waiting timeout: TimeInterval = 30) throws
        -> [TerminalCommandResult]
    {
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
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", script]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, recorder.results.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return recorder.results
    }

    func test_theWrappersMarksReportTheProgramsExitCode() throws {
        let results = try runWrapper(
            "printf '\\033]133;C\\007'; (exit 7); printf '\\033]133;D;%d\\007' $?; sleep 100")

        XCTAssertEqual(results.first?.exitCode, 7, "the D mark's status never reached the delegate")
    }

    func test_aFinishMarkWithoutAStartMark_reportsNothing() throws {
        // A mark that works arrives in well under a second, so a short settle is enough to prove silence.
        let results = try runWrapper("printf '\\033]133;D;%d\\007' 3; sleep 100", waiting: 3)

        XCTAssertTrue(results.isEmpty, "libghostty drops a stop with no start, so the C mark is required")
    }
}
