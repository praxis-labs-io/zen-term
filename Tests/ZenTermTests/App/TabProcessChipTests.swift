import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class TabProcessChipTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let jobs = ProgramJobs()
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
        jobs.stopAll()
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

    func test_aTabInTheHomeFolder_isNamedForTheUser_neverATilde() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.currentDirectory = URL(fileURLWithPath: NSHomeDirectory())

        c.pollTitlesForTesting()

        XCTAssertEqual(c.tabTitlesForTesting.first, NSUserName())
        XCTAssertFalse(c.tabTitlesForTesting.contains { $0.contains("~") })
    }

    func test_aScriptsTab_showsTheScript_notItsInterpreter() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("brew")
        try "#!/bin/bash\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let job = Process()
        job.executableURL = script
        try job.run()
        jobs.track(job)
        let deadline = Date().addingTimeInterval(5)
        while ProcessArguments.arguments(of: job.processIdentifier)?.last != script.path, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(ProcessArguments.programName(of: job.processIdentifier), "bash", "precondition: it runs as bash")

        pane.foregroundProcessGroupID = job.processIdentifier
        c.pollTitlesForTesting()

        XCTAssertEqual(try chipProcess(in: c)?.name, "Homebrew")
    }

    func test_aProgramWhoseArgumentsCannotBeRead_isUnknown_neverTheRestingShell() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        XCTAssertNil(ProcessArguments.arguments(of: 1), "precondition: launchd's arguments are not readable")

        pane.foregroundProcessGroupID = 1
        c.pollTitlesForTesting()

        XCTAssertEqual(try chipProcess(in: c), .unknown)
    }

    func test_aTabsChip_followsTheProgramInItsFocusedPane() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        XCTAssertEqual(try chipProcess(in: c), .shell, "a pane at its prompt shows the shell chip")

        pane.foregroundProcessGroupID = try jobs.start(named: "nvim")
        c.pollTitlesForTesting()
        XCTAssertEqual(try chipProcess(in: c)?.name, "Neovim")

        pane.foregroundProcessGroupID = try jobs.start(named: "fooctl")
        c.pollTitlesForTesting()
        XCTAssertEqual(try chipProcess(in: c), .unknown, "an unknown program gets the generic chip")

        pane.foregroundProcessGroupID = nil
        c.pollTitlesForTesting()
        XCTAssertEqual(try chipProcess(in: c), .shell, "back at the prompt, the shell chip returns")
    }

    func test_aTabIsNamedForTheProgramInItsFocusedPane_andForItsFolderBackAtThePrompt() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.currentDirectory = URL(fileURLWithPath: "/tmp/api", isDirectory: true)
        pane.title = "~/tmp/api"
        c.pollTitlesForTesting()
        XCTAssertEqual(c.tabTitlesForTesting.first, "api", "at a prompt, the folder outranks the shell's path title")

        pane.foregroundProcessGroupID = try jobs.start(named: "nvim")
        pane.title = "nvim Sources/App.swift"
        c.pollTitlesForTesting()
        XCTAssertEqual(c.tabTitlesForTesting.first, "nvim", "a job is named for its program, not its command line")

        pane.foregroundProcessGroupID = nil
        c.pollTitlesForTesting()
        XCTAssertEqual(c.tabTitlesForTesting.first, "api")
    }

    func test_aRenamedTab_keepsItsName_whateverRunsInIt() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let id = try XCTUnwrap(c.activeTabIDForTesting)
        c.renameTab(id, to: "api server")

        pane.foregroundProcessGroupID = try jobs.start(named: "htop")
        c.pollTitlesForTesting()

        XCTAssertEqual(c.tabTitlesForTesting.first, "api server")
    }
}
