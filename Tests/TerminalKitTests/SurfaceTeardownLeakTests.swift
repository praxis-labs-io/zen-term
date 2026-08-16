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
        // Not `try?`. A launch that fails leaves this process holding the pipe's only write end,
        // so nothing ever closes it and `readDataToEndOfFile` blocks forever on the main thread:
        // `swift test` hangs with no failure and no output, and no timeout above can bound it
        // because the hang is inside this call rather than in the poll loop.
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

    /// A ceiling on a broken start, not an estimate of a healthy one.
    ///
    /// Polling is what makes a generous ceiling nearly free: a green run returns the moment the
    /// marker appears and never pays this, so the cost falls only on a genuinely broken start.
    /// Sizing it to a warm machine instead bought nothing and cost the suite its credibility.
    /// Measured first-marker waits: 0.65s idle, 2.2s with the test process throttled to the
    /// background band, and past 3.0s for all six markers when that throttle covered the whole
    /// suite, which is milder than the concurrent `swift build` that first surfaced this. At the
    /// old 3.0s those six were the reported flake.
    ///
    /// Not larger than this, though. Every caller bails at its first missing marker, so a total
    /// break costs one ceiling per test rather than one per wait, and this bounds `bin/check` at
    /// about a minute of waiting before it says so. A gate that looks hung is one a developer
    /// interrupts, which buys a worse answer than a slightly tighter bound would have.
    private static let markerTimeout: TimeInterval = 15

    /// Poll for the worker rather than pumping a fixed interval: `zsh -l -i` sources the user's
    /// rc files first, which is fast on a warm machine and can take seconds on a cold one, so a
    /// fixed wait is both a flake and a tax paid on every green run.
    ///
    /// The interval backs off because each tick forks a `pgrep` that walks the whole process
    /// table. At a flat 50ms a full ceiling would spend that fork several hundred times, on the
    /// loaded machine whose scarce fork capacity is the very thing the shell is waiting for: the
    /// poll would then be part of why the marker is late. Staying at 50ms while it matters keeps
    /// a healthy start (0.65s) as prompt as before.
    private static let pollFloor: TimeInterval = 0.05
    private static let pollCeiling: TimeInterval = 0.25

    /// The same free-when-unused cap as `markerTimeout`, for the same reason.
    ///
    /// `drain` fires its completion on whichever lands first, the sweep finishing or this
    /// deadline, and gives the caller no way to tell which. So expiring here does not surface as
    /// a timeout: the leak assertions run against a sweep that has not finished, and the suite
    /// reports processes surviving teardown. That is a false leak in the exact code this suite
    /// exists to guard, which is a worse failure under load than the flake it removed.
    /// Measured at 0.25s under the load that broke the marker wait (0.15s idle) and it barely
    /// degrades, because the reaper waits on a process-exit source rather than polling.
    /// Leaving it at 3.0s was betting that the margin never closes; raising it costs a green run
    /// nothing, since the completion fires as soon as the sweep is done.
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

    /// Context for a marker that never appeared, so a timeout does not read as a leak in the
    /// teardown path it is actually testing. That misread once cost a session.
    ///
    /// It reports what it counted and stops there, because the tempting conclusions are both
    /// unsound. The count is process-wide: `leaderChildren` filters on `ppid == getpid()`, which
    /// scopes it to shells this test forked but not to one surface, and nothing here can make
    /// that attribution (`GhosttySurface.recordShellSessions` says the same). In the two tests
    /// that start two surfaces, a healthy sibling's leader is in this count, so reading a
    /// non-zero as "this surface's shell started" would be confidently wrong exactly there. Zero
    /// is no safer a conclusion: the filter also drops exited processes, so a shell that forked
    /// and died inside the wait is indistinguishable from one never forked, and the longer
    /// ceiling widens that window.
    ///
    /// A `pgrep` for the shell's command line is not an option either: `zsh -l -i` matches the
    /// developer's own open terminals, so it reports a shell that started when none did.
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
        // Callers `close()` rather than order out: an ordered-out window keeps its window-server
        // surface for the rest of the run, and this suite's own flakiness is load-sensitive.
        // `isReleasedWhenClosed` defaults to true for a window built in code,
        // so clear it or closing frees one the caller still holds.
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

    /// Two panes closed a moment apart, which is what closing a window or quitting does.
    ///
    /// Honest about its reach: this covers staggered teardowns end to end, but it does NOT
    /// isolate the watcher race it was written alongside. That race needs the second surface's
    /// leader to exit more than one poll interval later than the first, so the coalesced
    /// teardown is dropped AND orphans only after the first has been swept. Both leaders exit
    /// in about 45ms, so the window opens on timing variance, not on demand: reinstating the
    /// early-return watcher leaves this test green. It earns its keep as a real two-pane
    /// teardown, not as a regression guard for that race.
    func test_staggeredTeardownsBothGetSwept() throws {
        try skipOnCI()
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }

        let first = startSurface(script: "/bin/sleep 945 & /bin/sleep 999", in: window)
        let second = startSurface(script: "/bin/sleep 946 & /bin/sleep 999", in: window)
        // Idempotent, since `terminate()` no-ops once the surface is freed. It exists for the
        // bail-outs below: returning early without it would leave real shells running, which is
        // the leak this suite is here to catch.
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

        // The gap is the point. Terminated together, both leaders orphan together and a single
        // sweep gets them whatever the watcher does. Staggered, the second lands inside the
        // first's watch window (so it is coalesced rather than starting its own watcher) but
        // orphans after the first has been swept, which is the only moment a watcher that
        // stopped at its first find would leave nothing looking.
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
