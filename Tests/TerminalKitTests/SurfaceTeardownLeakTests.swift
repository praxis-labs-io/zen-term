import AppKit
import XCTest

@testable import TerminalKit

/// End-to-end proof that tearing a surface down takes its whole process tree with it.
/// This is ZEN-269's regression guard, so it runs in the ordinary suite. It opens a window
/// and spawns real shells, which a CI runner may not be able to back, so CI alone skips it.
final class SurfaceTeardownLeakTests: XCTestCase {
    /// GitHub Actions sets `CI`; a local `bin/check` does not.
    private func skipOnCI() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CI"] == nil,
            "needs a window server and real shells — skipped on CI")
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func pids(matching marker: String) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", marker]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").compactMap { pid_t($0) }
    }

    /// `script` must keep the shell alive, so teardown is what kills the marker, not the
    /// shell exiting on its own.
    private func assertNoLeak(
        script: String, marker: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/zsh", args: ["-l", "-i", "-c", script]))
        XCTAssertNotNil(surface.surfacePtr, "surface failed to start", file: file, line: line)
        pump(3.0)

        let spawned = pids(matching: marker)
        XCTAssertFalse(spawned.isEmpty, "marker \(marker) never spawned", file: file, line: line)

        surface.view.removeFromSuperview()
        surface.terminate()

        let swept = expectation(description: "sweep finished")
        ShellSessionReaper.shared.drain(timeout: 3.0) { swept.fulfill() }
        wait(for: [swept], timeout: 5.0)

        let survivors = spawned.filter { kill($0, 0) == 0 || errno == EPERM }
        survivors.forEach { kill($0, SIGKILL) }
        XCTAssertTrue(
            survivors.isEmpty, "\(marker) survived teardown: \(survivors)", file: file, line: line)
    }

    func test_backgroundJobDoesNotSurviveTeardown() throws {
        try skipOnCI()
        _ = NSApplication.shared
        assertNoLeak(script: "/bin/sleep 941 & /bin/sleep 999", marker: "sleep 941")
    }

    func test_childInItsOwnProcessGroupDoesNotSurviveTeardown() throws {
        try skipOnCI()
        _ = NSApplication.shared
        // The dev-server shape: a foreground job that puts its real worker in a new group.
        assertNoLeak(
            script: "/usr/bin/perl -e 'if (fork==0) { setpgrp(0,0); exec \"/bin/sleep 942\" } sleep 999'",
            marker: "sleep 942")
    }
}
