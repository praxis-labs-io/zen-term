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

    /// `marker` is an extended regex matched against the whole command line, anchored by its
    /// callers so it names the worker process and not the shell that spawned it — a shell's
    /// own command line contains the worker's, so an unanchored marker matches both and a
    /// failure then reports the wrong pid.
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

    /// Poll for the worker rather than pumping a fixed interval: `zsh -l -i` sources the user's
    /// rc files first, which is fast on a warm machine and can take seconds on a cold one, so a
    /// fixed wait is both a flake and a tax paid on every green run.
    private func waitForPids(matching marker: String, timeout: TimeInterval = 3.0) -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        var found = pids(matching: marker)
        while found.isEmpty, Date() < deadline {
            pump(0.05)
            found = pids(matching: marker)
        }
        return found
    }

    private func survivors(of pids: [pid_t]) -> [pid_t] {
        pids.filter { kill($0, 0) == 0 || errno == EPERM }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        return window
    }

    /// `script` must keep the shell alive, so teardown is what kills the marker, not the
    /// shell exiting on its own.
    private func startSurface(script: String, in window: NSWindow) -> GhosttySurface {
        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/zsh", args: ["-l", "-i", "-c", script]))
        return surface
    }

    private func teardownAndDrain(_ surface: GhosttySurface) {
        surface.view.removeFromSuperview()
        surface.terminate()
        let swept = expectation(description: "sweep finished")
        ShellSessionReaper.shared.drain(timeout: 3.0) { swept.fulfill() }
        wait(for: [swept], timeout: 5.0)
    }

    private func assertNoLeak(
        script: String, marker: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let surface = startSurface(script: script, in: window)
        XCTAssertNotNil(surface.surfacePtr, "surface failed to start", file: file, line: line)

        let spawned = waitForPids(matching: marker)
        XCTAssertFalse(spawned.isEmpty, "marker \(marker) never spawned", file: file, line: line)

        teardownAndDrain(surface)

        let leaked = survivors(of: spawned)
        leaked.forEach { kill($0, SIGKILL) }
        XCTAssertTrue(
            leaked.isEmpty, "\(marker) survived teardown: \(leaked)", file: file, line: line)
    }

    func test_backgroundJobDoesNotSurviveTeardown() throws {
        try skipOnCI()
        _ = NSApplication.shared
        assertNoLeak(script: "/bin/sleep 941 & /bin/sleep 999", marker: "^/bin/sleep 941$")
    }

    func test_childInItsOwnProcessGroupDoesNotSurviveTeardown() throws {
        try skipOnCI()
        _ = NSApplication.shared
        // The dev-server shape: a foreground job that puts its real worker in a new group.
        assertNoLeak(
            script: "/usr/bin/perl -e 'if (fork==0) { setpgrp(0,0); exec \"/bin/sleep 942\" } sleep 999'",
            marker: "^/bin/sleep 942$")
    }

    /// Closing one pane must not reach into another pane's processes, and must still leave the
    /// other pane sweepable when its own turn comes.
    ///
    /// Read the second half as the point. Both surfaces here start successfully, so this cannot
    /// reproduce the adoption bug it was originally written for: that needed a surface whose
    /// start FAILED to sit polling and adopt the next one's session. What it does guard is the
    /// general property that one teardown neither kills nor strands a sibling's session, which
    /// is the invariant the ledger exists to hold. Don't read it as coverage of attribution.
    func test_teardownLeavesASiblingSurfaceAlone() throws {
        try skipOnCI()
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.orderOut(nil) }

        // Started back to back with no turn of the run loop between them, the way
        // `PaneCanvasController.reconcileAndRender` starts a workspace's panes.
        let staying = startSurface(script: "/bin/sleep 943 & /bin/sleep 999", in: window)
        let closing = startSurface(script: "/bin/sleep 944 & /bin/sleep 999", in: window)
        XCTAssertNotNil(staying.surfacePtr, "sibling surface failed to start")
        XCTAssertNotNil(closing.surfacePtr, "surface failed to start")

        let stayingWorker = waitForPids(matching: "^/bin/sleep 943$")
        let closingWorker = waitForPids(matching: "^/bin/sleep 944$")
        XCTAssertFalse(stayingWorker.isEmpty, "sibling marker never spawned")
        XCTAssertFalse(closingWorker.isEmpty, "marker never spawned")
        defer { (stayingWorker + closingWorker).forEach { kill($0, SIGKILL) } }

        teardownAndDrain(closing)

        XCTAssertTrue(
            survivors(of: closingWorker).isEmpty,
            "sleep 944 survived teardown: \(survivors(of: closingWorker))")
        XCTAssertEqual(
            survivors(of: stayingWorker), stayingWorker,
            "tearing down one surface killed a live sibling's processes")

        // The sibling still has to be sweepable: a capture that adopted the wrong session
        // leaves this one held by nobody, which the assertion above cannot see.
        teardownAndDrain(staying)
        XCTAssertTrue(
            survivors(of: stayingWorker).isEmpty,
            "sibling's sleep 943 survived its own teardown: \(survivors(of: stayingWorker))")
    }
}
