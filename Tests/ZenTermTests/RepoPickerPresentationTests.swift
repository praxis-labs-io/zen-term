import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// How ⌘⇧P gets on screen now that the `workspaces` file is read off the main thread.
///
/// The card is built once the workspaces are in hand rather than presented empty and filled: a card
/// that springs in at one size and resizes a frame later reads as a flash. That makes the press and
/// the card two separate turns of the main queue, which is the shape that needs pinning — nothing
/// may present twice, and a load landing after the user changed their mind may not present at all.
@MainActor
final class RepoPickerPresentationTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func seedWorkspaces(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func pickers(in c: WindowController) -> [RepoPickerOverlay] {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }
    }

    private func workspaceRows(in picker: RepoPickerOverlay) -> [SelectableRowView] {
        picker.rowViews.compactMap { $0 as? SelectableRowView }
    }

    /// Wait for any load already enqueued to have landed. The load queue is serial and delivers on
    /// main, so a load enqueued now can only complete after the ones before it: when this one's
    /// completion runs, the card under test has had its chance to present. Waiting on a fixed delay
    /// instead would pass because nothing had time to happen, which is no assertion at all.
    private func waitForPendingLoads() {
        var landed = false
        ConfigLoader.loadWorkspaces { _ in landed = true }
        waitUntil(landed, "every enqueued workspaces load to land")
    }

    private let twoWorkspaces = """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        """

    private func createCards(in c: WindowController) -> [NewWorktreeOverlay] {
        descendants(of: c.window.contentView!).compactMap { $0 as? NewWorktreeOverlay }
    }

    /// The search field holds the keyboard, so arrows arrive through its `doCommandBy`.
    private func moveUp(in picker: RepoPickerOverlay) {
        let field = descendants(of: picker).compactMap { $0 as? NSTextField }
            .first { ($0.delegate as? PaletteOverlay) === picker }!
        _ = picker.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:)))
    }

    /// `NSWindow.sendEvent`'s path: a traversal from the content view, where a card claims it.
    private func pressEscape(in c: WindowController) -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return c.window.contentView!.performKeyEquivalent(with: esc)
    }

    /// Hand the picker a listing the way the background pass does, so a worktree row exists
    /// without a real repo on disk. The path never has to resolve: `WorktreeStore.state` failing is
    /// the "could not be read" branch of the confirm, which still confirms.
    private func giveWorktrees(_ picker: RepoPickerOverlay, under path: URL, _ branches: String...) {
        let worktrees = branches.map {
            Worktree(
                path: path.appendingPathComponent($0, isDirectory: true), branch: $0,
                head: "0000000", isLocked: false)
        }
        picker.setWorktrees(
            WorktreeListing(commonDir: path.appendingPathComponent(".git"), worktrees: worktrees),
            for: path)
    }

    /// The search field holds the keyboard, so arrows arrive through its `doCommandBy`.
    private func moveDown(in picker: RepoPickerOverlay) {
        let field = descendants(of: picker).compactMap { $0 as? NSTextField }
            .first { ($0.delegate as? PaletteOverlay) === picker }!
        _ = picker.control(
            field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
    }

    private func pressEscapeThroughTheResponder(in c: WindowController) {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        guard let content = c.window.contentView else { return }
        if content.performKeyEquivalent(with: esc) { return }
        (c.window.firstResponder as? NSView)?.keyDown(with: esc)
    }

    // MARK: ⌥⌫ routing

    /// The modal gate's switch ends in `default: return`, so an unmatched case is swallowed.
    func test_removeWorktree_overAWorktreeRow_confirms() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
        let alpha = URL(
            fileURLWithPath: NSString("~/Dev/alpha").expandingTildeInPath, isDirectory: true)
        giveWorktrees(picker, under: alpha, "feature/one")
        moveDown(in: picker)

        c.handle(.removeWorktree)

        waitUntil(picker.presentedConfirmForTesting != nil, "the remove confirm to be presented")
        // The row being asked about has to stay on screen, and it becomes the progress state the
        // moment the answer is yes. A confirm that replaced the picker took both away.
        XCTAssertTrue(pickers(in: c).contains { $0 === picker }, "the picker is not replaced")
        XCTAssertFalse(c.isConfirmOpen, "a card, never the toast confirm")
    }

    /// A workspace is a checkout the user configured, not a worktree of ours.
    func test_removeWorktree_overAWorkspaceRow_confirmsNothing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")

        c.handle(.removeWorktree)
        waitForPendingLoads()

        XCTAssertNil(pickers(in: c).first?.presentedConfirmForTesting)
        XCTAssertFalse(pickers(in: c).isEmpty, "the picker is left where it was")
    }

    /// The other half of `PickerChordGuard`: outside the picker, nothing may present.
    func test_removeWorktree_withNoPickerUp_presentsNothing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.removeWorktree)
        waitForPendingLoads()

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertTrue(pickers(in: c).isEmpty)
    }

    /// Esc answers the confirm, not the picker: the list underneath is still where the user was.
    func test_cancellingTheRemoveConfirm_leavesThePickerUp() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
        let alpha = URL(
            fileURLWithPath: NSString("~/Dev/alpha").expandingTildeInPath, isDirectory: true)
        giveWorktrees(picker, under: alpha, "feature/one")
        moveDown(in: picker)
        c.handle(.removeWorktree)
        waitUntil(picker.presentedConfirmForTesting != nil, "the remove confirm to be presented")

        pressEscapeThroughTheResponder(in: c)

        XCTAssertNil(picker.presentedConfirmForTesting)
        XCTAssertTrue(pickers(in: c).contains { $0 === picker }, "the picker never left")
    }

    /// The whole point of the card over the toast: answering yes turns the row that was asked
    /// about into the progress state, in the list the user was already looking at.
    func test_confirmingTheRemove_leavesThePickerUpWithTheRowRemoving() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        // `AppDelegate` owns this wiring in the app; a bare window has to stand in for it.
        c.worktreeRemovals.onChanged = { [weak c] relisting in
            c?.worktreeRemovalsChanged(relisting: relisting)
        }
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
        // The picker lists worktrees in the background on open, and those answers are empty here.
        // Seeding before they land would have the row wiped out from under the test.
        waitForPendingLoads()
        let alpha = URL(
            fileURLWithPath: NSString("~/Dev/alpha").expandingTildeInPath, isDirectory: true)
        giveWorktrees(picker, under: alpha, "feature/one")
        moveDown(in: picker)
        c.handle(.removeWorktree)
        waitUntil(picker.presentedConfirmForTesting != nil, "the remove confirm to be presented")
        let card = try XCTUnwrap(picker.presentedConfirmForTesting)

        try XCTUnwrap(button(in: card, title: "Remove")).onTap()

        XCTAssertTrue(pickers(in: c).contains { $0 === picker }, "the picker is never rebuilt")
        XCTAssertNil(picker.presentedConfirmForTesting, "the confirm is answered and gone")
        XCTAssertTrue(
            picker.rowViews.contains { $0 is RepoPickerOverlay.RemovingRowView },
            "the row says what is happening to it")
    }

    private func button(in card: NSView, title: String) -> AppButton? {
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        return descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    // MARK: ⌥⏎ routing

    /// The modal gate's switch ends in `default: return`, so an unmatched case is swallowed.
    func test_createWorktree_overThePicker_swapsItForTheCreateCard() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")

        c.handle(.createWorktree)

        waitUntil(!createCards(in: c).isEmpty, "the create card to be presented")
        XCTAssertTrue(pickers(in: c).isEmpty, "one modal slot, so the card replaces the picker")
    }

    /// The other half of `PickerChordGuard`: outside the picker, nothing may present.
    func test_createWorktree_withNoPickerUp_presentsNothing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.createWorktree)
        waitForPendingLoads()

        XCTAssertTrue(createCards(in: c).isEmpty)
        XCTAssertTrue(pickers(in: c).isEmpty)
    }

    /// The ＋ row has no workspace to cut from.
    func test_createWorktree_overTheAddRow_presentsNothing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
        moveUp(in: picker)

        c.handle(.createWorktree)
        waitForPendingLoads()

        XCTAssertTrue(createCards(in: c).isEmpty)
        XCTAssertFalse(pickers(in: c).isEmpty, "the picker is left where it was")
    }

    /// ⌥⏎ is a detour from a row, unlike the ＋ row's form, which is a way out of the list.
    func test_cancellingTheCreateCard_reopensThePicker() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        c.handle(.createWorktree)
        waitUntil(!createCards(in: c).isEmpty, "the create card to be presented")

        XCTAssertTrue(pressEscape(in: c), "the card claims Esc in performKeyEquivalent")

        waitUntil(!pickers(in: c).isEmpty, "the picker to come back")
        XCTAssertTrue(createCards(in: c).isEmpty)
    }

    /// A create outlives its card: any surface chord closes one, and a tab-bar click does too. The
    /// answer must not land on whatever replaced it, and a failure must not vanish with it.
    func test_aCardClosedMidCreate_isNotTheOneTheAnswerLandsOn() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        c.handle(.createWorktree)
        waitUntil(!createCards(in: c).isEmpty, "the create card to be presented")
        let card = try XCTUnwrap(createCards(in: c).first)
        card.beginWork("Creating spike")

        c.handle(.toggleCommandPalette)

        waitForPendingLoads()
        XCTAssertTrue(createCards(in: c).isEmpty, "the gate closed it out from under the create")
        XCTAssertFalse(c.isPresentingForTesting(card), "so the answer has to go somewhere else")
    }

    /// The card must arrive already holding its rows. Presenting first and filling after is what
    /// made the open flash: the list height is what sizes the card, so entries landing a frame later
    /// resize it mid-spring.
    func test_picker_isPresentedWithItsRowsAlreadyIn() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)

        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
        XCTAssertEqual(
            workspaceRows(in: picker).count, 3,
            "the ＋ row and a row per workspace, all present when the card first appears")
    }

    /// The press and the card are separate turns now, so a second press lands while nothing is on
    /// screen. It has to read as the toggle it is rather than starting a second card.
    func test_secondPressBeforeTheCardArrives_leavesNoPicker() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)
        c.handle(.toggleRepoPicker)  // pressed again before the load landed

        waitForPendingLoads()

        XCTAssertTrue(pickers(in: c).isEmpty, "press-press is open-then-close, not two cards")
        XCTAssertFalse(c.isModalOverlayOpen)
    }

    /// Opening another card between the press and the picker means the user moved on before
    /// anything was drawn. The load landing afterwards must not put the picker up over it.
    ///
    /// Note what this does NOT cover: a bare Esc in that window. Esc is claimed by a card's own
    /// `performKeyEquivalent`, and there is no card yet, so it reaches the terminal instead and the
    /// picker still arrives. That gap is its own bug, and naming this test for Esc would have hidden it.
    func test_anotherCardOpeningBeforeThePickerArrives_stopsItFromAppearing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)
        c.handle(.toggleCommandPalette)  // any other card calls off the pending one on its way up

        waitForPendingLoads()

        XCTAssertTrue(pickers(in: c).isEmpty, "the picker the user moved on from must not arrive")
        XCTAssertFalse(
            descendants(of: c.window.contentView!).compactMap { $0 as? CommandPaletteOverlay }.isEmpty,
            "the card they did ask for is the one that's up")
    }

    /// A tool float is modal over the window too, and it opens synchronously when it needs no repo
    /// root — so it can get on screen inside the picker's load window. The picker landing on top of
    /// it is the two-stacked-surfaces state the whole guard exists to prevent.
    func test_aFloatOpeningBeforeThePickerArrives_stopsItFromAppearing() throws {
        try seedWorkspaces(twoWorkspaces)
        GeneralConfig.setCurrentForTesting(floatConfig)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)
        c.handle(.toggleToolFloat("yazi"))  // opens right away: no git gate, no directory anchor

        waitForPendingLoads()

        XCTAssertTrue(pickers(in: c).isEmpty, "the picker must not land on top of an open float")
        XCTAssertTrue(c.floatsForTesting.isOpen, "the float the user actually opened is the one up")
    }

    /// A plain float: no `git:` gate and not `persist:directory`, so `toggle` needs no repo-root
    /// probe and the card is up in the same turn as the chord.
    private var floatConfig: GeneralConfig {
        var config = GeneralConfig.builtIn
        config.floats = [
            ToolFloat(
                id: "yazi", order: 0, title: "yazi", icon: ToolFloatParser.defaultIcon, command: "yazi",
                dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
                persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "y"))
        ]
        return config
    }
}
