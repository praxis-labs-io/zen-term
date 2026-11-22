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
}
