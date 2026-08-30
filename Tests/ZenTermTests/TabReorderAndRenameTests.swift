import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Moving and renaming a tab, driven through the window the way a keystroke and a double-click
/// reach it. `TabListTests` proves the ordering maths and `TabBarViewTests` the editor; what is
/// only provable here is the wiring between them — that the chords dispatch, that a committed name
/// reaches the bar, and that the rename editor holds the keyboard while it is open.
@MainActor
final class TabReorderAndRenameTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(GeneralConfig.builtIn)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-tabmove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow(tabs: Int = 1) -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.mountAndStart()
        controllers.append(controller)
        for _ in 1..<max(tabs, 1) { controller.newTabForTesting() }
        return controller
    }

    // MARK: reorder

    func test_moveTabChords_shiftTheActiveTabAndKeepItActive() throws {
        let controller = makeWindow(tabs: 3)
        let order = controller.tabOrderForTesting
        let active = try XCTUnwrap(controller.activeTabIDForTesting)
        XCTAssertEqual(active, order[2], "a new tab lands active and rightmost")

        controller.handle(.moveTabLeft)

        XCTAssertEqual(controller.tabOrderForTesting, [order[0], order[2], order[1]])
        XCTAssertEqual(controller.activeTabIDForTesting, active, "the moved tab keeps the selection")

        controller.handle(.moveTabRight)

        XCTAssertEqual(controller.tabOrderForTesting, order, "and back")
    }

    /// ⌘1-9 is resolved from `tabs.order` at render time, so a move has to renumber the tabs. If
    /// the index were stored anywhere, this is what would catch it.
    func test_movingATab_renumbersTheSelectTabChords() throws {
        let controller = makeWindow(tabs: 3)
        let moved = try XCTUnwrap(controller.activeTabIDForTesting)

        controller.handle(.moveTabLeft)  // the active tab goes from slot 3 to slot 2
        controller.handle(.selectTab(2))

        XCTAssertEqual(controller.activeTabIDForTesting, moved, "⌘2 now selects the tab that moved")
    }

    func test_moveTabLeft_atTheWall_doesNothing() throws {
        let controller = makeWindow(tabs: 2)
        controller.handle(.selectTab(1))
        let order = controller.tabOrderForTesting

        controller.handle(.moveTabLeft)

        XCTAssertEqual(controller.tabOrderForTesting, order)
        XCTAssertEqual(controller.activeTabIDForTesting, order[0])
    }

    // MARK: rename

    private func rename(_ controller: WindowController, to name: String) throws {
        controller.handle(.renameTab)
        let field = try XCTUnwrap(
            controller.tabBarForTesting.renameEditorForTesting, "⌘P → Rename Tab opens the editor")
        field.stringValue = name
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        _ = controller.tabBarForTesting.control(
            field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    func test_renameTab_commitsThroughToTheBar() throws {
        let controller = makeWindow(tabs: 2)

        try rename(controller, to: "api server")

        XCTAssertEqual(controller.tabTitlesForTesting.last, "api server")
    }

    /// The reset path. An empty commit clears the pin, so the tab goes back to reporting its own
    /// live cwd title rather than being stuck on an empty label.
    func test_renamingToNothing_restoresTheLiveTitle() throws {
        let controller = makeWindow(tabs: 2)
        let live = try XCTUnwrap(controller.tabTitlesForTesting.last)
        try rename(controller, to: "api server")
        XCTAssertEqual(controller.tabTitlesForTesting.last, "api server")

        try rename(controller, to: "")

        XCTAssertEqual(controller.tabTitlesForTesting.last, live)
        XCTAssertFalse(live.isEmpty, "the live title is a real title, so the assertion means something")
    }

    /// `KeyInterceptor` runs its monitor ahead of the responder chain, so without an explicit gate
    /// ⌘W closes a pane while you are typing a name into the bar.
    func test_whileRenaming_chordsAreSwallowed() throws {
        let controller = makeWindow(tabs: 2)
        let order = controller.tabOrderForTesting
        controller.handle(.renameTab)
        XCTAssertTrue(controller.tabBarForTesting.isRenaming)

        controller.handle(.closePane)
        controller.handle(.newTab)
        controller.handle(.moveTabLeft)

        XCTAssertEqual(controller.tabOrderForTesting, order, "no tab opened, closed or moved")
        XCTAssertTrue(controller.tabBarForTesting.isRenaming, "and the editor is still up")
    }
}
