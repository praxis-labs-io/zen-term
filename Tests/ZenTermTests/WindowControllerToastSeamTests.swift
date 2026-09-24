import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowControllerToastSeamTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-toast-seam-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        ConfigReset.toBuiltIn()
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    private func configText() throws -> String {
        try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func button(_ title: String, on toast: ToastView) throws -> AppButton {
        try XCTUnwrap(descendants(of: toast).compactMap { $0 as? AppButton }.first { $0.title == title })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func assertClaimsNoKeys(
        _ toast: ToastView, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for keyCode: UInt16 in [36, 76, 51, 53, 49] {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: keyCode)!
            XCTAssertFalse(
                toast.performKeyEquivalent(with: event), "\(message) (keyCode \(keyCode))",
                file: file, line: line)
        }
    }

    private func toastViews(in controller: WindowController) -> [ToastView] {
        guard let root = controller.window.contentView else { return [] }
        return descendants(of: root).compactMap { $0 as? ToastView }
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        return controller
    }

    func test_showToast_mountsAVisibleToastInTheWindow() throws {
        let controller = makeController()
        XCTAssertTrue(toastViews(in: controller).isEmpty, "no toast before one is asked for")

        controller.showToast(
            ConfigDiagnostic.toast(for: [
                ConfigDiagnostic(
                    scope: .keybind(.splitVertical),
                    problem: .chordTaken(Chord(command: true, shift: true, key: "\\"), by: .toggleZoom))
            ])!)

        let toasts = toastViews(in: controller)
        XCTAssertEqual(toasts.count, 1, "the seam must actually mount a toast, not swallow it")
        let labels = descendants(of: toasts[0]).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("Split Vertically") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("toggle_focus_mode") }, "\(labels)")
    }

    func test_showToast_isReachableFromTheKeyWindowLookup() {
        let controller = makeController()
        controller.showToast(ToastContent(variant: .warning, title: "Title", message: "Body"))
        XCTAssertEqual(toastViews(in: controller).count, 1)
    }

    private func keycaps(in toast: ToastView) -> [String] {
        descendants(of: toast).compactMap { ($0 as? KeycapView)?.shortcut }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-toast-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try """
        background = #010101
        foreground = #fefefe
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    func test_waitingToast_showsTheCommandKeycapForItsTab() throws {
        let controller = makeController()
        controller.newTabForTesting()

        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()

        let toast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))
        XCTAssertEqual(keycaps(in: toast), ["⌘1"], "the toast for tab 1 names ⌘1")
    }

    func test_waitingToast_withKeycap_stillArmsNoKeyEquivalents() throws {
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()

        let toast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))
        assertClaimsNoKeys(toast, "a sticky toast claims no Return/Esc, keycap or not")
        XCTAssertFalse(toast.acceptsFirstResponder, "and it never takes focus from the terminal")
    }

    func test_waitingToast_underAutoDismiss_clearsItself() throws {
        try seed("attention-toast = auto\ntoast-duration = 1\n")
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()
        XCTAssertEqual(toastViews(in: controller).count, 1, "it still appears")

        settle(1.5)

        XCTAssertTrue(toastViews(in: controller).isEmpty, "and then clears itself")
        XCTAssertEqual(
            controller.attentionStateForTesting(tabIndex: 0), .waiting,
            "but the tab keeps its number colored: the agent is still waiting")
    }

    func test_autoDismissedWaitingToast_dropsTheWindowsHandleToIt() throws {
        try seed("attention-toast = auto\ntoast-duration = 1\n")
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()
        XCTAssertNotNil(controller.waitingToastForTesting(tabIndex: 0), "the handle is taken first")

        settle(1.5)

        XCTAssertNil(
            controller.waitingToastForTesting(tabIndex: 0),
            "the handle goes with the card, rather than pointing at a view that left the stack")
    }

    // Reduce Motion is pinned off: with it on, the outgoing card's `onDismissed` runs before the replacement lands and the check goes untested.
    func test_aReplacementSurvives_theOutgoingCardsDismissal() throws {
        Motion.isReduceMotionEnabled = { false }
        try seed("attention-toast = auto\ntoast-duration = 1\n")
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "first")
        drainMainQueue()
        let first = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))

        controller.notifyAgentForTesting(tabIndex: 0, message: "second")
        drainMainQueue()
        let second = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))
        XCTAssertFalse(first === second, "the second notification replaces the card")

        settle(0.6)

        XCTAssertTrue(
            controller.waitingToastForTesting(tabIndex: 0) === second,
            "the outgoing card must not clear the handle its replacement now owns")
    }

    func test_waitingToast_underSticky_staysUp() throws {
        try seed("attention-toast = sticky\ntoast-duration = 1\n")
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()

        settle(1.5)

        XCTAssertEqual(toastViews(in: controller).count, 1, "no timer was armed")
    }

    func test_waitingToast_reappliesTheme_whenTheConfigChanges() throws {
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()
        let toast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))
        let stale = toast.layer?.backgroundColor

        let original = Theme.current
        addTeardownBlock { Theme.setCurrentForTesting(original) }
        Theme.setCurrentForTesting(try makeAlternateTheme())
        NotificationCenter.default.post(name: .configDidChange, object: nil)
        drainMainQueue()

        XCTAssertNotEqual(
            toast.layer?.backgroundColor, stale,
            "a live waiting toast must recolor with the chrome, not keep the old theme's fill")
        XCTAssertEqual(
            toast.layer?.backgroundColor, Theme.current.chrome.background.nsColor.cgColor)
    }

    func test_waitingToast_keycapFollowsItsTab_whenAnEarlierTabCloses() throws {
        let controller = makeController()
        controller.newTabForTesting()
        controller.newTabForTesting()
        controller.selectTabForTesting(index: 0)
        controller.notifyAgentForTesting(tabIndex: 2, message: "needs your input")
        drainMainQueue()
        let toast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 2))
        XCTAssertEqual(keycaps(in: toast), ["⌘3"])

        controller.closeTabForTesting(index: 0)

        XCTAssertEqual(keycaps(in: toast), ["⌘2"], "the keycap must follow the tab, not go stale at ⌘3")
    }

    func test_longCommandInBackgroundTabShowsCompletedAttention() throws {
        let controller = makeController()
        controller.newTabForTesting()

        controller.notifyCommandFinishedForTesting(
            tabIndex: 0, result: TerminalCommandResult(exitCode: 0, duration: 126))
        drainMainQueue()

        XCTAssertEqual(controller.attentionStateForTesting(tabIndex: 0), .completed)
        let toast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))
        let copy = descendants(of: toast).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(copy.contains("Finished in 2m 6s."))
        XCTAssertEqual(keycaps(in: toast), ["⌘1"])
    }

    func test_shortCommandStaysQuiet() {
        let controller = makeController()
        controller.newTabForTesting()

        controller.notifyCommandFinishedForTesting(
            tabIndex: 0, result: TerminalCommandResult(exitCode: 0, duration: 9.999))
        drainMainQueue()

        XCTAssertNil(controller.attentionStateForTesting(tabIndex: 0))
    }

    func test_longCommandInActiveTabStaysQuiet() {
        let controller = makeController()

        controller.notifyCommandFinishedForTesting(
            tabIndex: 0, result: TerminalCommandResult(exitCode: 0, duration: 60))
        drainMainQueue()

        XCTAssertNil(controller.attentionStateForTesting(tabIndex: 0))
    }

    func test_commandCompletionDoesNotReplaceAgentWaitingState() throws {
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()
        let waitingToast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))

        controller.notifyCommandFinishedForTesting(
            tabIndex: 0, result: TerminalCommandResult(exitCode: 0, duration: 60))
        drainMainQueue()

        XCTAssertEqual(controller.attentionStateForTesting(tabIndex: 0), .waiting)
        XCTAssertTrue(controller.waitingToastForTesting(tabIndex: 0) === waitingToast)
    }

    func test_failedCommandMessageCarriesExitAndElapsed() {
        XCTAssertEqual(
            WindowController.commandResultMessage(
                TerminalCommandResult(exitCode: 1, duration: 3_661)),
            "Exited 1 after 1h 1m 1s.")
    }

    func test_stoppedCommandMessageSaysStopped() {
        XCTAssertEqual(
            WindowController.commandResultMessage(
                TerminalCommandResult(exitCode: 130, duration: 3_661)),
            "Stopped after 1h 1m 1s.")
    }

    func test_configDiagnosticsToast_mountsWithOpenSettingsAndDismiss() throws {
        let controller = makeController()
        let content = try XCTUnwrap(
            ConfigDiagnostic.toast(for: [
                ConfigDiagnostic(scope: .setting(key: "font-size"), problem: .clamped(value: "200", to: "72"))
            ]))
        controller.showConfigDiagnosticsToast(content, landingScope: .setting(key: "font-size"))

        let toasts = toastViews(in: controller)
        XCTAssertEqual(toasts.count, 1, "the config toast must mount, not be swallowed")
        let titles = descendants(of: toasts[0]).compactMap { ($0 as? AppButton)?.title }
        XCTAssertEqual(Set(titles), ["Dismiss", "Open Settings"], "\(titles)")
    }

    func test_configDiagnosticsToast_armsNoKeyEquivalents() {
        let controller = makeController()
        controller.showConfigDiagnosticsToast(
            ToastContent(variant: .warning, title: "t", message: "m"), landingScope: .keybindLine)
        let toast = toastViews(in: controller)[0]
        assertClaimsNoKeys(toast, "a sticky toast claims no Return/Esc")
        XCTAssertFalse(toast.acceptsFirstResponder, "and it never takes focus from the terminal")
    }

    private func conflict(
        loser: KeyInterceptor.ReservedChord, chord: Chord, winner: KeyInterceptor.ReservedChord
    ) -> KeybindConflict {
        KeybindConflict(loser: loser, chord: chord, winner: winner)
    }

    func test_conflictToast_carriesAcceptAndRevert() throws {
        let controller = makeController()

        controller.showConflictToasts([
            conflict(loser: .toggleCommandPalette, chord: Chord(command: true, key: "p"), winner: .splitVertical)
        ])

        let toasts = toastViews(in: controller)
        XCTAssertEqual(toasts.count, 1)
        let titles = descendants(of: toasts[0]).compactMap { ($0 as? AppButton)?.title }
        XCTAssertEqual(Set(titles), ["Accept", "Revert"], "\(titles)")
    }

    func test_conflictToast_fromAFloat_offersAcceptAlone() throws {
        let controller = makeController()

        controller.showConflictToasts([
            conflict(
                loser: .findNext, chord: Chord(command: true, key: "g"),
                winner: .toggleToolFloat("lazygit"))
        ])

        let titles = descendants(of: toastViews(in: controller)[0]).compactMap { ($0 as? AppButton)?.title }
        XCTAssertEqual(titles, ["Accept"], "\(titles)")
    }

    func test_conflictToast_aFailedWrite_leavesTheCardUp() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))
        let file = tempRoot.appendingPathComponent("config")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        try button("Accept", on: toastViews(in: controller)[0]).onTap()

        settle(1.0)
        XCTAssertEqual(toastViews(in: controller).count, 1, "the card stays, so it can be retried")
    }

    func test_reShowingAReducedSet_keepsTheSurvivingCard() {
        let controller = makeController()
        let a = conflict(loser: .findNext, chord: Chord(command: true, key: "g"), winner: .toggleToolFloat("a"))
        let b = conflict(loser: .searchSelection, chord: Chord(command: true, key: "e"), winner: .toggleToolFloat("b"))
        controller.showConflictToasts([a, b])
        let before = toastViews(in: controller)
        XCTAssertEqual(before.count, 2)

        controller.showConflictToasts([b])

        waitUntil(toastViews(in: controller).count == 1, "the answered card comes down")
        XCTAssertTrue(
            toastViews(in: controller)[0] === before[1],
            "and the survivor is the SAME view, not a replacement that animated back in")
    }

    func test_reShowingAGrownSet_keepsTheExistingCard() {
        let controller = makeController()
        let a = conflict(loser: .findNext, chord: Chord(command: true, key: "g"), winner: .toggleToolFloat("a"))
        let b = conflict(loser: .searchSelection, chord: Chord(command: true, key: "e"), winner: .toggleToolFloat("b"))
        controller.showConflictToasts([a])
        let first = toastViews(in: controller)[0]

        controller.showConflictToasts([a, b])

        let now = toastViews(in: controller)
        XCTAssertEqual(now.count, 2)
        XCTAssertTrue(now.contains { $0 === first }, "the card already up is untouched")
    }

    func test_dismissChord_takesTheConflictCardDown_withoutWriting() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let before = try configText()
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))
        XCTAssertEqual(toastViews(in: controller).count, 1)

        controller.handle(.dismissToast)

        waitUntil(toastViews(in: controller).isEmpty, "the card comes down")
        XCTAssertEqual(try configText(), before, "byte-identical: a dismiss key writes nothing")
        XCTAssertEqual(
            KeybindConflict.all(in: .current).map(\.loser), [.toggleCommandPalette],
            "and the conflict is still outstanding, so the next launch raises it again")
    }

    func test_dismissAllChord_takesEveryConflictCardDown_withoutWriting() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let before = try configText()
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))

        controller.handle(.dismissAllToasts)

        waitUntil(toastViews(in: controller).isEmpty, "every card comes down")
        XCTAssertEqual(try configText(), before, "byte-identical")
    }

    func test_conflictToast_close_dismissesWithoutWriting() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let before = try configText()
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))
        let toast = toastViews(in: controller)[0]

        try XCTUnwrap(descendants(of: toast).compactMap { $0 as? IconButton }.first).onClick()

        waitUntil(toastViews(in: controller).isEmpty, "the card comes down")
        XCTAssertEqual(try configText(), before, "byte-identical: closing writes nothing")
        XCTAssertEqual(
            KeybindConflict.all(in: .current).map(\.loser), [.toggleCommandPalette],
            "and it is still outstanding, so the next launch raises it again")
    }

    func test_theDiagnosticsNotice_hasNoCloseAffordance() throws {
        let controller = makeController()
        let content = try XCTUnwrap(
            ConfigDiagnostic.toast(for: [
                ConfigDiagnostic(scope: .setting(key: "font-size"), problem: .clamped(value: "200", to: "72"))
            ]))

        controller.showConfigDiagnosticsToast(content, landingScope: .setting(key: "font-size"))

        let toast = toastViews(in: controller)[0]
        XCTAssertFalse(descendants(of: toast).compactMap { $0 as? AppButton }.isEmpty, "it has buttons")
        XCTAssertTrue(
            descendants(of: toast).compactMap { $0 as? IconButton }.isEmpty,
            "but no ×, because nothing here would answer it")
    }

    func test_aPassiveToast_hasNoCloseAffordance() {
        let controller = makeController()
        controller.showToast(ToastContent(variant: .info, title: "t", message: "m"))

        let toast = toastViews(in: controller)[0]
        XCTAssertTrue(descendants(of: toast).compactMap { $0 as? IconButton }.isEmpty)
    }

    func test_conflictToast_accept_writesTheUnset() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))

        try button("Accept", on: toastViews(in: controller)[0]).onTap()

        XCTAssertEqual(GeneralConfig.current.unboundActions, [.toggleCommandPalette])
        let text = try configText()
        XCTAssertTrue(text.contains("keybind = toggle_command_palette=none"), text)
        XCTAssertEqual(KeybindConflict.all(in: .current), [], "and nothing reports it again")
    }

    func test_conflictToast_revert_dropsTheLineThatTookTheChord() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))

        try button("Revert", on: toastViews(in: controller)[0]).onTap()

        let text = try configText()
        XCTAssertFalse(text.contains("split_vertical"), text)
        XCTAssertEqual(GeneralConfig.current.keymap[Chord(command: true, shift: true, key: "p")], .toggleCommandPalette)
        XCTAssertEqual(KeybindConflict.all(in: .current), [])
    }

    func test_conflictToast_answering_dismissesTheCard() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))

        try button("Accept", on: toastViews(in: controller)[0]).onTap()

        waitUntil(toastViews(in: controller).isEmpty, "the answered card comes down")
    }

    func test_threeConflicts_mountThreeCards() {
        let controller = makeController()

        controller.showConflictToasts([
            conflict(loser: .findNext, chord: Chord(command: true, key: "g"), winner: .toggleToolFloat("a")),
            conflict(
                loser: .findPrevious, chord: Chord(command: true, shift: true, key: "g"),
                winner: .toggleToolFloat("b")),
            conflict(loser: .searchSelection, chord: Chord(command: true, key: "e"), winner: .toggleToolFloat("c")),
        ])

        XCTAssertEqual(toastViews(in: controller).count, 3)
    }

    func test_conflictToast_armsNoKeyEquivalents() {
        let controller = makeController()
        controller.showConflictToasts([
            conflict(loser: .findNext, chord: Chord(command: true, key: "g"), winner: .splitVertical)
        ])

        let toast = toastViews(in: controller)[0]
        assertClaimsNoKeys(toast, "neither button arms a key")
        XCTAssertFalse(toast.acceptsFirstResponder, "and the card never takes focus from the terminal")
    }

    func test_dismissConflictToasts_takesThemAllDown() {
        let controller = makeController()
        controller.showConflictToasts([
            conflict(loser: .findNext, chord: Chord(command: true, key: "g"), winner: .toggleToolFloat("a")),
            conflict(loser: .searchSelection, chord: Chord(command: true, key: "e"), winner: .toggleToolFloat("b")),
        ])
        XCTAssertEqual(toastViews(in: controller).count, 2)

        controller.dismissConflictToasts()

        waitUntil(toastViews(in: controller).isEmpty, "both cards come down")
    }

    func test_configDiagnosticsToast_openSettingsButton_opensTheSettingsCard() throws {
        let controller = makeController()
        controller.showConfigDiagnosticsToast(
            ToastContent(variant: .warning, title: "t", message: "m"), landingScope: .setting(key: "font-size"))
        let toast = toastViews(in: controller)[0]
        let openButton = try XCTUnwrap(
            descendants(of: toast).compactMap { $0 as? AppButton }.first { $0.title == "Open Settings" })
        XCTAssertFalse(controller.isModalOverlayOpen, "no card before the tap")
        openButton.onTap()
        XCTAssertTrue(controller.isModalOverlayOpen, "Open Settings must open the Settings card")
    }
}
