import AppKit
import XCTest

@testable import TerminalKit

final class SurfaceTeardownLeakTests: XCTestCase {
    private func skipOnCI() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CI"] == nil,
            "needs a window server and real shells — skipped on CI")
    }

    private func skipUnlessStarted(_ what: String, _ surfaces: GhosttySurface...) throws {
        try XCTSkipIf(
            surfaces.contains { $0.surfacePtr == nil },
            "\(what) did not start: no window server, which a locked or sleeping screen does")
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

    private static let markerTimeout: TimeInterval = 15

    private static let pollFloor: TimeInterval = 0.05
    private static let pollCeiling: TimeInterval = 0.25

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
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

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
        try skipUnlessStarted("the surface", surface)

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

    // Does not isolate the watcher race: reinstating it leaves this green.
    func test_staggeredTeardownsBothGetSwept() throws {
        try skipOnCI()
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }

        let first = startSurface(script: "/bin/sleep 945 & /bin/sleep 999", in: window)
        let second = startSurface(script: "/bin/sleep 946 & /bin/sleep 999", in: window)
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
        try assertNoLeak(
            script: "/usr/bin/perl -e 'if (fork==0) { setpgrp(0,0); exec \"/bin/sleep 942\" } sleep 999'",
            marker: "^/bin/sleep 942$")
    }

    func test_teardownLeavesASiblingSurfaceAlone() throws {
        try skipOnCI()
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }

        let staying = startSurface(script: "/bin/sleep 943 & /bin/sleep 999", in: window)
        let closing = startSurface(script: "/bin/sleep 944 & /bin/sleep 999", in: window)
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

        teardownAndDrain(staying)
        XCTAssertTrue(
            survivors(of: stayingWorker).isEmpty,
            "sibling's sleep 943 survived its own teardown: \(survivors(of: stayingWorker))")
    }
}
