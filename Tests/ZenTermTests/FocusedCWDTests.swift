import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// `focusedCWD` answers "which directory am I in", and four things ask it: ⌘D's repo walk, ⌘T and
/// ⌘N under `tab-inherit-cwd`, and where a `persist:dir` tool float anchors. It used to read
/// the pane canvas unconditionally, so a drawer you had `cd`'d elsewhere reported the pane's
/// directory and every one of those four went to the wrong place.
///
/// Driven through the real drawer chord, because the bug was in which panel the tab *considered*
/// focused: a test that read the canvas directly would agree with the bug.
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
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.showAndStart()
        controller = c
        return c
    }

    /// A drawer holding focus reports *its* directory, not the pane's. This is the reported bug:
    /// `cd` in a drawer, press ⌘D, and the main pane's repo came up.
    func test_focusedCWD_followsTheFocusedDrawer() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.currentDirectory = root

        // Opening the bottom drawer focuses it (`focusDrawer`), and its shell is a new surface.
        c.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(spawned.last)
        XCTAssertFalse(drawer === pane, "the drawer spawns its own shell")
        drawer.currentDirectory = elsewhere

        XCTAssertEqual(
            c.focusedCWD, elsewhere,
            "a focused drawer's cwd is the tab's cwd — this is what ⌘D walks for a repo root")
    }

    /// Focus back on the canvas and the pane answers again, so the fix doesn't just swap which
    /// panel is hardcoded.
    func test_focusedCWD_returnsToThePaneWhenTheDrawerCloses() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.currentDirectory = root

        c.handle(.toggleBottomDrawer)
        try XCTUnwrap(spawned.last).currentDirectory = elsewhere
        XCTAssertEqual(c.focusedCWD, elsewhere)

        c.handle(.toggleBottomDrawer)  // dismissed, focus returns to the canvas
        XCTAssertEqual(c.focusedCWD, root, "with the drawer shut the pane answers again")
    }

    /// A drawer whose backend can't resolve a cwd falls back to the pane rather than nil, because
    /// nil reads downstream as "not a repository" rather than "unknown".
    func test_focusedCWD_unresolvableDrawer_fallsBackToThePane() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        pane.currentDirectory = root

        c.handle(.toggleBottomDrawer)
        try XCTUnwrap(spawned.last).currentDirectory = nil

        XCTAssertEqual(c.focusedCWD, root, "an unknown drawer cwd must not read as no-repository")
    }
}
