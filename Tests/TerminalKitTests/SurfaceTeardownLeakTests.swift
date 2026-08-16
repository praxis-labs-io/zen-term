import AppKit
import XCTest

@testable import TerminalKit

/// End-to-end proof that tearing a surface down takes its whole process tree with it.
/// This is the regression guard, so it runs in the ordinary suite. It opens a window
/// and spawns real shells, which a CI runner may not be able to back, so CI alone skips it.
final class SurfaceTeardownLeakTests: XCTestCase {
    /// GitHub Actions sets `CI`; a local `bin/check` does not.
    private func skipOnCI() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CI"] == nil,
            "needs a window server and real shells — skipped on CI")
    }

    /// A locked or sleeping screen takes the window server away, and `ghostty_surface_new` then
    /// returns nil. Skipping says so; failing looks exactly like the teardown bug under test.
    private func skipUnlessStarted(_ what: String, _ surfaces: GhosttySurface...) throws {
        try XCTSkipIf(
            surfaces.contains { $0.surfacePtr == nil },
            "\(what) did not start: no window server, which a locked or sleeping screen does")
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
        // Not `try?`: a failed launch leaves this process holding the pipe's only write end, and
        // the read below then blocks forever, inside this call where no timeout above can bound it.
        do {
            try p.run()
        } catch {
            XCTFail("could not launch /usr/bin/pgrep: \(error)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").compactMap { pid_t($0) }
    }

    /// A ceiling on a broken start, not an estimate: polling returns the moment the marker appears
    /// (0.65s idle, 2.2s throttled), and one per test bounds `bin/check` at about a minute.
    private static let markerTimeout: TimeInterval = 15

    /// Polled, not a fixed wait: `zsh -l -i` sources rc files, seconds on a cold machine. It backs
    /// off because each tick forks a `pgrep`, competing for the capacity the shell is waiting on.
    private static let pollFloor: TimeInterval = 0.05
    private static let pollCeiling: TimeInterval = 0.25

    /// Free when unused, like `markerTimeout`: `drain` completes as soon as the sweep does, and
    /// expiring instead reports a false leak rather than a timeout (0.15s idle, 0.25s loaded).
    private static let drainTimeout: TimeInterval = 15

    private func waitForPids(
        matching marker: String, timeout: TimeInterval = markerTimeout
    ) -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        var interval = Self.pollFloor
        var found = pids(matching: marker)
        while found.isEmpty, Date() < deadline {
            pump(interval)
            interval = min(interval * 1.5, Self.pollCeiling)
            found = pids(matching: marker)
        }
        return found
    }

    /// Context for a marker that never appeared, so a timeout does not read as a leak in the very
    /// teardown path under test. It counts and stops: neither number supports a conclusion.
    private func startDiagnosis() -> String {
        let leaders = ShellSession.leaderChildren().count
        return "\(leaders) shell leader(s) alive under this test process at the deadline"
    }

    private func survivors(of pids: [pid_t]) -> [pid_t] {
        pids.filter { kill($0, 0) == 0 || errno == EPERM }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        // Callers `close()` rather than order out, which would hold a window-server surface all
        // run. `isReleasedWhenClosed` defaults true in code, so closing would free a live one.
        window.isReleasedWhenClosed = false
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
        ShellSessionReaper.shared.drain(timeout: Self.drainTimeout) { swept.fulfill() }
        wait(for: [swept], timeout: Self.drainTimeout * 2)
    }

    private func assertNoLeak(
        script: String, marker: String, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let window = makeWindow()
        defer { window.close() }

        let surface = startSurface(script: script, in: window)
        // Throws rather than asserting and falling through: a surface that never came up would
        // otherwise wait out the whole marker ceiling and then blame the shell half for it.
        try skipUnlessStarted("the surface", surface)

        // So this is reachable only with a live surface, and a failure here is the shell half.
        let spawned = waitForPids(matching: marker)
        guard !spawned.isEmpty else {
            XCTFail(
                "marker \(marker) never spawned within \(Self.markerTimeout)s: \(startDiagnosis())",
                file: file, line: line)
            teardownAndDrain(surface)
            return
        }

        teardownAndDrain(surface)

        let leaked = survivors(of: spawned)
        leaked.forEach { kill($0, SIGKILL) }
        XCTAssertTrue(
            leaked.isEmpty, "\(marker) survived teardown: \(leaked)", file: file, line: line)
    }

    /// Two panes closed a moment apart, which is what closing a window or quitting does. Honest
    /// about reach: it does NOT isolate the watcher race, which reinstated leaves this green.
    func test_staggeredTeardownsBothGetSwept() throws {
        try skipOnCI()
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }

        let first = startSurface(script: "/bin/sleep 945 & /bin/sleep 999", in: window)
        let second = startSurface(script: "/bin/sleep 946 & /bin/sleep 999", in: window)
        // Idempotent; for the bail-outs below, which would otherwise leave real shells running,
        // the very leak this suite exists to catch.
        defer { [first, second].forEach { $0.terminate() } }
        try skipUnlessStarted("both surfaces", first, second)

        let firstWorker = waitForPids(matching: "^/bin/sleep 945$")
        defer { firstWorker.forEach { kill($0, SIGKILL) } }
        guard !firstWorker.isEmpty else {
            XCTFail(
                "first marker never spawned within \(Self.markerTimeout)s: \(startDiagnosis())")
            return
        }
        let secondWorker = waitForPids(matching: "^/bin/sleep 946$")
        defer { secondWorker.forEach { kill($0, SIGKILL) } }
        guard !secondWorker.isEmpty else {
            XCTFail(
                "second marker never spawned within \(Self.markerTimeout)s: \(startDiagnosis())")
            return
        }

        // The gap is the point: staggered, the second is coalesced into the first's watch window
        // but orphans after that sweep, the one moment a stop-at-first-find watcher looks away.
        first.view.removeFromSuperview()
        first.terminate()
        Thread.sleep(forTimeInterval: 0.06)
        second.view.removeFromSuperview()
        second.terminate()

        let swept = expectation(description: "sweep finished")
        ShellSessionReaper.shared.drain(timeout: Self.drainTimeout) { swept.fulfill() }
        wait(for: [swept], timeout: Self.drainTimeout * 2)

        XCTAssertTrue(
            survivors(of: firstWorker).isEmpty,
            "sleep 945 survived: \(survivors(of: firstWorker))")
        XCTAssertTrue(
            survivors(of: secondWorker).isEmpty,
            "the second teardown was dropped, sleep 946 survived: \(survivors(of: secondWorker))")
    }

    func test_backgroundJobDoesNotSurviveTeardown() throws {
        try skipOnCI()
        _ = NSApplication.shared
        try assertNoLeak(script: "/bin/sleep 941 & /bin/sleep 999", marker: "^/bin/sleep 941$")
    }

    func test_childInItsOwnProcessGroupDoesNotSurviveTeardown() throws {
        try skipOnCI()
        _ = NSApplication.shared
        // The dev-server shape: a foreground job that puts its real worker in a new group.
        try assertNoLeak(
            script: "/usr/bin/perl -e 'if (fork==0) { setpgrp(0,0); exec \"/bin/sleep 942\" } sleep 999'",
            marker: "^/bin/sleep 942$")
    }

    /// One teardown neither kills nor strands a sibling's session. Not coverage of attribution:
    /// both surfaces start here, and the adoption bug needed one whose start FAILED.
    func test_teardownLeavesASiblingSurfaceAlone() throws {
        try skipOnCI()
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }

        // Started back to back with no turn of the run loop between them, the way
        // `PaneCanvasController.reconcileAndRender` starts a workspace's panes.
        let staying = startSurface(script: "/bin/sleep 943 & /bin/sleep 999", in: window)
        let closing = startSurface(script: "/bin/sleep 944 & /bin/sleep 999", in: window)
        // Idempotent; see the same defer in `test_staggeredTeardownsBothGetSwept`.
        defer { [staying, closing].forEach { $0.terminate() } }
        try skipUnlessStarted("the sibling and closing surfaces", staying, closing)

        let stayingWorker = waitForPids(matching: "^/bin/sleep 943$")
        defer { stayingWorker.forEach { kill($0, SIGKILL) } }
        guard !stayingWorker.isEmpty else {
            XCTFail(
                "sibling marker never spawned within \(Self.markerTimeout)s: \(startDiagnosis())")
            return
        }
        let closingWorker = waitForPids(matching: "^/bin/sleep 944$")
        defer { closingWorker.forEach { kill($0, SIGKILL) } }
        guard !closingWorker.isEmpty else {
            XCTFail("marker never spawned within \(Self.markerTimeout)s: \(startDiagnosis())")
            return
        }

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
