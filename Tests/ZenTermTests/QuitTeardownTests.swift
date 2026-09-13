import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class QuitTeardownTests: WindowTestCase {
    private var spawned: [RecordingSurface] = []
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        spawned = []
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
    }

    override func tearDown() {
        TerminalSurfaceFactory.makeOverride = nil
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        super.tearDown()
    }

    private func makeController() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), initialCWD: nil)
        controller = c
        c.mountAndStart()
        return c
    }

    func test_tearDownForQuitTerminatesEverySurface() {
        let c = makeController()
        XCTAssertFalse(spawned.isEmpty, "no surface was created")
        XCTAssertFalse(spawned.contains { $0.terminated }, "surfaces died before the quit")

        c.tearDownForQuit()

        XCTAssertTrue(spawned.allSatisfy { $0.terminated }, "quit left surfaces running")
    }

    func test_tearDownForQuitTerminatesDrawerSurfaces() {
        let c = makeController()
        c.handle(.toggleBottomDrawer)
        XCTAssertGreaterThanOrEqual(spawned.count, 2, "drawer surface was never created")

        c.tearDownForQuit()

        XCTAssertTrue(spawned.allSatisfy { $0.terminated }, "quit left the drawer's shell running")
    }

    func test_quitTeardownTerminatesEverySurfaceThenCompletesOnce() {
        let delegate = AppDelegate()
        delegate.addWindowForTesting()
        XCTAssertFalse(spawned.isEmpty, "no surface was created")
        XCTAssertFalse(spawned.contains { $0.terminated }, "surfaces died before the quit")

        var completions = 0
        let done = expectation(description: "quit teardown completed")
        delegate.quitTeardownForTesting {
            completions += 1
            if completions == 1 { done.fulfill() }
        }
        wait(for: [done], timeout: 10)

        XCTAssertTrue(spawned.allSatisfy { $0.terminated }, "quit left surfaces running")

        let settled = expectation(description: "past the drain cap")
        DispatchQueue.main.asyncAfter(deadline: .now() + ShellSessionReaper.quitSweepBudget + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 10)
        XCTAssertEqual(completions, 1, "quit must complete exactly once")
    }

    func test_terminatingWithNoWindowsStillWaitsForTheSweep() {
        let delegate = AppDelegate()
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApp), .terminateLater,
            "quit with no windows must wait for the in-flight sweep, not exit immediately")
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    func test_tearDownForQuitIsIdempotentWithTheCloseButton() {
        let c = makeController()
        c.tearDownForQuit()
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(spawned.allSatisfy { $0.terminated })
    }
}
