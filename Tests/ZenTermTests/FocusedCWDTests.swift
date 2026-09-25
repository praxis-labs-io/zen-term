import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class FocusedCWDTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-focused-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.mountAndStart()
        controller = c
        return c
    }

    func test_focusedCWD_followsTheFocusedDrawer() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.currentDirectory = root

        c.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(spawned.last)
        XCTAssertFalse(drawer === pane, "the drawer spawns its own shell")
        drawer.currentDirectory = elsewhere

        XCTAssertEqual(
            c.sessionCWD, elsewhere,
            "a focused drawer's cwd is the tab's cwd — this is what ⌘D walks for a repo root")
    }

    func test_focusedCWD_returnsToThePaneWhenTheDrawerCloses() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.currentDirectory = root

        c.handle(.toggleBottomDrawer)
        try XCTUnwrap(spawned.last).currentDirectory = elsewhere
        XCTAssertEqual(c.sessionCWD, elsewhere)

        c.handle(.toggleBottomDrawer)
        XCTAssertEqual(c.sessionCWD, root, "with the drawer shut the pane answers again")
    }

    func test_focusedCWD_unresolvableDrawer_fallsBackToThePane() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.currentDirectory = root

        c.handle(.toggleBottomDrawer)
        try XCTUnwrap(spawned.last).currentDirectory = nil

        XCTAssertEqual(c.sessionCWD, root, "an unknown drawer cwd must not read as no-repository")
    }
}
