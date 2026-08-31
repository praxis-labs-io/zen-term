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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func renameCard(_ controller: WindowController) throws -> RenameTabOverlay {
        let content = try XCTUnwrap(controller.window.contentView)
        return try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? RenameTabOverlay }.first,
            "the rename card should be up")
    }

    private func rename(_ controller: WindowController, to name: String) throws {
        controller.handle(.renameTab)
        let card = try renameCard(controller)
        card.nameFieldForTesting.setText(name)
        card.renameButtonForTesting.onTap()
    }

    func test_renameTab_commitsThroughToTheBar() throws {
        let controller = makeWindow(tabs: 2)

        try rename(controller, to: "api server")

        XCTAssertEqual(controller.tabTitlesForTesting.last, "api server")
    }

    /// The card opens holding the name the tab already has, so a small edit does not mean retyping
    /// it, and its placeholder is the folder name the reset falls back to.
    func test_theCardOpensSeededWithTheCurrentName() throws {
        let controller = makeWindow(tabs: 2)
        let live = try XCTUnwrap(controller.tabTitlesForTesting.last)
        try rename(controller, to: "api server")  // pin a name, so current and live now differ

        controller.handle(.renameTab)

        let card = try renameCard(controller)
        XCTAssertEqual(card.nameFieldForTesting.text, "api server", "the name it carries, not the folder")
        XCTAssertEqual(card.nameFieldForTesting.placeholder, live, "the folder name, as the reset hint")
        XCTAssertNotEqual(live, "api server", "otherwise this test proves nothing")
    }

    /// The reset path. An empty commit clears the pin, so the tab goes back to reporting its own
    /// live cwd title rather than being stuck on an empty label.
    func test_renamingToNothing_restoresTheLiveTitle() throws {
        let controller = makeWindow(tabs: 2)
        let live = try XCTUnwrap(controller.tabTitlesForTesting.last)
        try rename(controller, to: "api server")
        XCTAssertEqual(controller.tabTitlesForTesting.last, "api server")

        try rename(controller, to: "   ")

        XCTAssertEqual(controller.tabTitlesForTesting.last, live)
        XCTAssertFalse(live.isEmpty, "the live title is a real title, so the assertion means something")
    }

    /// A double-click on a chip is the mouse route to the same card, and it renames the tab that
    /// was clicked rather than whichever one happens to be active.
    func test_theBarsDoubleClickOpensTheCardForThatTab() throws {
        let controller = makeWindow(tabs: 2)
        controller.handle(.selectTab(1))

        controller.renameTabForTesting(index: 1)
        let card = try renameCard(controller)
        card.nameFieldForTesting.setText("second")
        card.renameButtonForTesting.onTap()

        XCTAssertEqual(controller.tabTitlesForTesting.last, "second", "the clicked tab, not the active one")
    }

    /// The card takes the single modal slot, which is what gates the keyboard: `KeyInterceptor`
    /// runs ahead of the responder chain, so ⌘W would otherwise close a pane while you type.
    func test_whileTheCardIsUp_chordsAreSwallowed() throws {
        let controller = makeWindow(tabs: 2)
        let order = controller.tabOrderForTesting
        controller.handle(.renameTab)

        controller.handle(.closePane)
        controller.handle(.newTab)
        controller.handle(.moveTabLeft)

        XCTAssertEqual(controller.tabOrderForTesting, order, "no tab opened, closed or moved")
        XCTAssertNoThrow(try renameCard(controller), "and the card is still up")
    }

    /// Esc closes it and renames nothing.
    func test_cancelling_leavesTheTitleAlone() throws {
        let controller = makeWindow(tabs: 2)
        let live = try XCTUnwrap(controller.tabTitlesForTesting.last)
        controller.handle(.renameTab)
        let card = try renameCard(controller)

        card.nameFieldForTesting.setText("discarded")
        XCTAssertTrue(card.performKeyEquivalent(with: try Self.escapeEvent()))

        XCTAssertEqual(controller.tabTitlesForTesting.last, live)
    }

    private static func escapeEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
    }

    // MARK: the card is a card

    /// Every chord that presents a modal card closes a shown tool float first. Rename shipped in
    /// the pass-through group instead, which stacked the card on top of the float: two modal
    /// surfaces up at once, with the keyboard aimed at one of them.
    func test_openingTheCardOverAShownFloat_closesTheFloat() throws {
        let controller = makeWindow(tabs: 2)
        controller.floatsForTesting.toggle(
            ToolFloat(
                id: "probe", order: 0, title: "Probe", icon: ToolFloatParser.defaultIcon,
                command: "true", dir: nil, widthFraction: 0.6, heightFraction: 0.6,
                requiresGitRepo: false, persist: .ephemeral,
                toggle: Chord(command: true, shift: true, key: "y")))
        XCTAssertTrue(controller.floatsForTesting.isOpen, "the float is up")

        controller.handle(.renameTab)

        XCTAssertFalse(controller.floatsForTesting.isOpen, "the float closes before the card opens")
        XCTAssertNoThrow(try renameCard(controller), "and the card is up")
    }

    /// A pending destructive confirm outranks the card. The keyboard route is already gated on
    /// `isConfirmOpen`, but double-clicking the ACTIVE chip is not: `select` returns early on the
    /// tab already being active, before its own `cancelConfirm()`, so the card would land on top
    /// of a confirm that then cannot be answered.
    func test_doubleClickingTheActiveChip_answersAPendingConfirmFirst() throws {
        let controller = makeWindow(tabs: 2)
        var confirmed = 0
        controller.presentConfirm(
            variant: .warning, title: "Close 2 panes", message: "This closes both.",
            confirmLabel: "Close", onConfirm: { confirmed += 1 })
        XCTAssertTrue(controller.isConfirmOpen)

        controller.renameTabForTesting(index: 1)  // index 1 is the active tab

        XCTAssertFalse(controller.isConfirmOpen, "the confirm is cleared, not buried")
        XCTAssertEqual(confirmed, 0, "and cleared means cancelled, never silently confirmed")
    }
}
