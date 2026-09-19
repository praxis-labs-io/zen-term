import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

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

    private func moveUp(in picker: RepoPickerOverlay) {
        let field = descendants(of: picker).compactMap { $0 as? NSTextField }
            .first { ($0.delegate as? PaletteOverlay) === picker }!
        _ = picker.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:)))
    }

    private func pressEscape(in c: WindowController) -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return c.window.contentView!.performKeyEquivalent(with: esc)
    }

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
        XCTAssertTrue(pickers(in: c).contains { $0 === picker }, "the picker is not replaced")
        XCTAssertFalse(c.isConfirmOpen, "a card, never the toast confirm")
    }

    func test_clickingAndDraggingAcrossTheConfirm_opensNoRowBeneathIt() throws {
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
        c.window.contentView?.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(picker.presentedConfirmForTesting)
        let text = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Couldn't read") })
        var opened = 0
        for row in descendants(of: picker).compactMap({ $0 as? SelectableRowView }) {
            let activate = row.onActivate
            row.onActivate = {
                opened += 1
                activate?()
            }
        }
        func mouse(_ type: NSEvent.EventType, atX x: CGFloat) throws -> NSEvent {
            let point = text.convert(NSPoint(x: x, y: text.bounds.midY), to: nil)
            return try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        c.window.makeKeyAndOrderFront(nil)
        c.window.sendEvent(try mouse(.leftMouseDown, atX: text.bounds.minX + 10))
        c.window.sendEvent(try mouse(.leftMouseDragged, atX: text.bounds.midX))
        c.window.sendEvent(try mouse(.leftMouseUp, atX: text.bounds.midX))

        XCTAssertEqual(opened, 0)
        XCTAssertTrue(pickers(in: c).contains { $0 === picker }, "the picker is still up")
        XCTAssertTrue(picker.presentedConfirmForTesting === card, "the question is still up")
    }

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

    func test_removeWorktree_withNoPickerUp_presentsNothing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.removeWorktree)
        waitForPendingLoads()

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertTrue(pickers(in: c).isEmpty)
    }

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

    func test_chordsAreSwallowedWhileTheConfirmIsUp() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
        waitForPendingLoads()
        let alpha = URL(
            fileURLWithPath: NSString("~/Dev/alpha").expandingTildeInPath, isDirectory: true)
        giveWorktrees(picker, under: alpha, "feature/one")
        moveDown(in: picker)
        c.handle(.removeWorktree)
        waitUntil(picker.presentedConfirmForTesting != nil, "the remove confirm to be presented")
        let card = try XCTUnwrap(picker.presentedConfirmForTesting)

        c.handle(.createWorktree)
        c.handle(.removeWorktree)
        c.handle(.toggleRepoPicker)
        waitForPendingLoads()

        XCTAssertTrue(picker.presentedConfirmForTesting === card, "the same question, still up")
        XCTAssertTrue(pickers(in: c).contains { $0 === picker }, "and the same picker under it")
    }

    func test_confirmingTheRemove_leavesThePickerUpWithTheRowRemoving() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.worktreeRemovals.onChanged = { [weak c] change in c?.worktreeRemovalsChanged(change) }
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
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
        XCTAssertEqual(
            c.tabOrderForTesting.count, 1, "the tabs go when the folder does, not when it is asked")
        XCTAssertTrue(
            picker.rowViews.contains { $0 is RepoPickerOverlay.RemovingRowView },
            "the row says what is happening to it")
    }

    func test_theTabClosingOnARemoval_leavesThePickerUp() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        let removed = URL(
            fileURLWithPath: NSString("~/Dev/alpha/feature/one").expandingTildeInPath,
            isDirectory: true)
        c.openWorkspaceForTesting(
            Workspace(
                title: "feature/one", path: removed, main: nil, right: nil, bottom: nil,
                focus: .main, env: [:]))
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        let picker = try XCTUnwrap(pickers(in: c).first)
        XCTAssertEqual(c.tabCount(atPath: removed), 1)

        c.worktreeRemovalsChanged(.removed(removed))

        XCTAssertEqual(c.tabCount(atPath: removed), 0, "the tab goes with the folder")
        XCTAssertTrue(pickers(in: c).contains { $0 === picker }, "the picker does not")
    }

    private func button(in card: NSView, title: String) -> AppButton? {
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        return descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    func test_createWorktree_overThePicker_swapsItForTheCreateCard() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")

        c.handle(.createWorktree)

        waitUntil(!createCards(in: c).isEmpty, "the create card to be presented")
        XCTAssertTrue(pickers(in: c).isEmpty, "one modal slot, so the card replaces the picker")
    }

    func test_createWorktree_withNoPickerUp_presentsNothing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.createWorktree)
        waitForPendingLoads()

        XCTAssertTrue(createCards(in: c).isEmpty)
        XCTAssertTrue(pickers(in: c).isEmpty)
    }

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

    func test_secondPressBeforeTheCardArrives_leavesNoPicker() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)
        c.handle(.toggleRepoPicker)

        waitForPendingLoads()

        XCTAssertTrue(pickers(in: c).isEmpty, "press-press is open-then-close, not two cards")
        XCTAssertFalse(c.isModalOverlayOpen)
    }

    func test_anotherCardOpeningBeforeThePickerArrives_stopsItFromAppearing() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)
        c.handle(.toggleCommandPalette)

        waitForPendingLoads()

        XCTAssertTrue(pickers(in: c).isEmpty, "the picker the user moved on from must not arrive")
        XCTAssertFalse(
            descendants(of: c.window.contentView!).compactMap { $0 as? CommandPaletteOverlay }.isEmpty,
            "the card they did ask for is the one that's up")
    }

    func test_aFloatOpeningBeforeThePickerArrives_stopsItFromAppearing() throws {
        try seedWorkspaces(twoWorkspaces)
        GeneralConfig.setCurrentForTesting(floatConfig)
        let c = makeWindow()

        c.handle(.toggleRepoPicker)
        c.handle(.toggleToolFloat("yazi"))

        waitForPendingLoads()

        XCTAssertTrue(pickers(in: c).isEmpty, "the picker must not land on top of an open float")
        XCTAssertTrue(c.floatsForTesting.isOpen, "the float the user actually opened is the one up")
    }

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

    private func pressReturn(in picker: RepoPickerOverlay) {
        let field = descendants(of: picker).compactMap { $0 as? NSTextField }
            .first { ($0.delegate as? PaletteOverlay) === picker }!
        _ = picker.control(
            field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func openPicker(in c: WindowController) throws -> RepoPickerOverlay {
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        return try XCTUnwrap(pickers(in: c).first)
    }

    func test_returnOnAClosedWorkspace_opensItIntoTheSidebar_andSwitchesToIt() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        let homeTab = try XCTUnwrap(c.tabIDsForTesting(workspace: home).first)
        let homeSurface = try XCTUnwrap(c.controllerForTesting(tab: homeTab)?.allSurfaces.first)

        pressReturn(in: try openPicker(in: c))

        XCTAssertEqual(c.workspaceNamesForTesting, ["Home", "Alpha"], "a new workspace goes at the end")
        XCTAssertNotEqual(c.activeWorkspaceIDForTesting, home)
        XCTAssertEqual(c.tabOrderForTesting.count, 1, "it starts with its own tab, not one added to Home")
        XCTAssertEqual(
            c.controllerForTesting(tab: homeTab)?.allSurfaces.first.map { $0 === homeSurface }, true,
            "Home keeps running behind it")
        XCTAssertTrue(pickers(in: c).isEmpty, "the picker closes")
    }

    func test_returnOnAnOpenWorkspace_switchesToIt_ratherThanOpeningItAgain() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting
        pressReturn(in: try openPicker(in: c))
        let alpha = c.activeWorkspaceIDForTesting
        let alphaTab = try XCTUnwrap(c.tabIDsForTesting(workspace: alpha).first)
        let alphaSurface = try XCTUnwrap(c.controllerForTesting(tab: alphaTab)?.allSurfaces.first)
        c.handle(.selectWorkspace(1))
        XCTAssertEqual(c.activeWorkspaceIDForTesting, home)

        pressReturn(in: try openPicker(in: c))

        XCTAssertEqual(c.workspaceNamesForTesting, ["Home", "Alpha"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, alpha)
        XCTAssertTrue(c.controllerForTesting(tab: alphaTab)?.allSurfaces.first === alphaSurface)
    }

    func test_renamingAnOpenWorkspace_stillSwitchesToIt_ratherThanOpeningASecondCopy() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        pressReturn(in: try openPicker(in: c))
        let alpha = c.activeWorkspaceIDForTesting
        c.handle(.selectWorkspace(1))
        try seedWorkspaces(twoWorkspaces.replacingOccurrences(of: "[Alpha]", with: "[Alpha Renamed]"))

        pressReturn(in: try openPicker(in: c))

        XCTAssertEqual(c.workspaceNamesForTesting, ["Home", "Alpha"], "the same folder is the same workspace")
        XCTAssertEqual(c.activeWorkspaceIDForTesting, alpha)
    }

    func test_aConfiguredWorkspaceInTheHomeFolder_opensItsOwnWorkspace_notHome() throws {
        try seedWorkspaces("[Dotfiles]\npath = ~\n")
        let c = makeWindow()
        let home = c.activeWorkspaceIDForTesting

        pressReturn(in: try openPicker(in: c))

        XCTAssertEqual(c.workspaceNamesForTesting, ["Home", "Dotfiles"])
        XCTAssertNotEqual(c.activeWorkspaceIDForTesting, home)
    }

    func test_returnOnAnOpenWorktree_switchesToIt_ratherThanOpeningItAgain() throws {
        try seedWorkspaces(twoWorkspaces)
        let c = makeWindow()
        let alpha = URL(fileURLWithPath: NSString("~/Dev/alpha").expandingTildeInPath, isDirectory: true)
        var picker = try openPicker(in: c)
        giveWorktrees(picker, under: alpha, "feature/one")
        moveDown(in: picker)
        pressReturn(in: picker)
        let worktree = c.activeWorkspaceIDForTesting
        XCTAssertEqual(c.workspaceNamesForTesting, ["Home", "Alpha: feature/one"])
        c.handle(.selectWorkspace(1))

        picker = try openPicker(in: c)
        giveWorktrees(picker, under: alpha, "feature/one")
        moveDown(in: picker)
        pressReturn(in: picker)

        XCTAssertEqual(c.workspaceNamesForTesting, ["Home", "Alpha: feature/one"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, worktree)
    }
}
