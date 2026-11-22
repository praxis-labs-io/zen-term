import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class TabProcessChipTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var jobs: [Process] = []
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        jobs.forEach { $0.terminate() }
        jobs = []
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func chipProcess(in c: WindowController) throws -> ProcessIcon? {
        let tabBar = try XCTUnwrap(descendants(of: c.containerForTesting).compactMap { $0 as? TabBarView }.first)
        return try XCTUnwrap(tabBar.chipsForTesting.first).processBadgeForTesting?.process
    }

    // A real process whose argv[0] is `name`, which is how a pane's program is read.
    private func job(named name: String) throws -> pid_t {
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        job.arguments = ["-e", "exec {'/bin/sleep'} '\(name)', '30'"]
        try job.run()
        jobs.append(job)
        let pid = job.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        while ProcessArguments.programName(of: pid) != name, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(ProcessArguments.programName(of: pid), name, "precondition: the job runs as \(name)")
        return pid
    }

    func test_aTabsChip_followsTheProgramInItsFocusedPane() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        XCTAssertEqual(try chipProcess(in: c), .shell, "a pane at its prompt shows the shell chip")

        pane.foregroundProcessGroupID = try job(named: "nvim")
        c.pollTitlesForTesting()
        XCTAssertEqual(try chipProcess(in: c)?.name, "Neovim")

        pane.foregroundProcessGroupID = try job(named: "fooctl")
        c.pollTitlesForTesting()
        XCTAssertEqual(try chipProcess(in: c), .unknown, "an unknown program gets the generic chip")

        pane.foregroundProcessGroupID = nil
        c.pollTitlesForTesting()
        XCTAssertEqual(try chipProcess(in: c), .shell, "back at the prompt, the shell chip returns")
    }
}
