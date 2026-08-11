import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// `WindowController.showToast` is the seam `AppDelegate` routes app-global notices through — today
/// the config keybind conflicts. The content is unit-tested elsewhere; this asserts the
/// notice actually reaches the screen, per the house rule that a control tested only through its
/// view-model can ship dead. A silent no-op here would leave the whole feature invisible.
@MainActor
final class WindowControllerToastSeamTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        // A real ghostty surface needs a live libghostty app; inject a headless stub instead.
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        // Sandboxed: a conflict card's buttons WRITE, so without this they would edit the real config.
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
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// Write a config into the sandboxed root and reload.
    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    private func configText() throws -> String {
        try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
    }

    /// Pump the runloop for `seconds` of wall clock, past a spring-out and the stack collapse that
    /// follows it. `RunLoop.run(mode:before:)` returns immediately when nothing is attached, so a
    /// single call waits for nothing at all and an "it is still there" assertion holds either way.
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

    private func toastViews(in controller: WindowController) -> [ToastView] {
        guard let root = controller.window.contentView else { return [] }
        return descendants(of: root).compactMap { $0 as? ToastView }
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
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
        // Assert the rendered text, not the content struct — the struct is already unit-tested; what
        // could still be broken is the card rendering something other than what it was handed.
        let labels = descendants(of: toasts[0]).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("Split Vertically") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("toggle_focus_mode") }, "\(labels)")
    }

    func test_showToast_isReachableFromTheKeyWindowLookup() {
        // AppDelegate routes through `keyController()`, which falls back to the first window when
        // none is key (the headless case here). If the seam weren't public to it, this wouldn't
        // compile — and the config toast would never have a window to land in.
        let controller = makeController()
        controller.showToast(ToastContent(variant: .warning, title: "Title", message: "Body"))
        XCTAssertEqual(toastViews(in: controller).count, 1)
    }

    // MARK: the claude / waiting toast

    /// The keycaps a toast currently draws, read off the rendered view tree — a mirror of the
    /// resolved string would pass while the card drew nothing.
    private func keycaps(in toast: ToastView) -> [String] {
        descendants(of: toast).compactMap { ($0 as? KeycapView)?.shortcut }
    }

    /// A notification arrives off the terminal's read path, so `agentNotified` hops to main before
    /// touching the UI — the toast doesn't exist until the queue drains. This block is enqueued
    /// after it, and the main queue is FIFO, so waiting on this is deterministic, not a sleep.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    /// A theme that differs from the current one, loaded through the real config path (mirrors
    /// `ReapplyThemeTests`) — so "did it recolor" compares against genuinely different values.
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

    /// ⌘1–⌘9 already switch tabs while a claude toast is up — it's deliberately non-modal. The
    /// toast just never said so; now its Switch action carries the keycap.
    func test_waitingToast_showsTheCommandKeycapForItsTab() throws {
        let controller = makeController()
        controller.newTabForTesting()  // tab 2, now active; tab 1 is in the background

        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()

        let toast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))
        XCTAssertEqual(keycaps(in: toast), ["⌘1"], "the toast for tab 1 names ⌘1")
    }

    /// Displaying a keycap must not arm a key equivalent — the guarantee that a toast never
    /// steals keys from the terminal. The binding named is the app's, not the toast's.
    func test_waitingToast_withKeycap_stillArmsNoKeyEquivalents() throws {
        let controller = makeController()
        controller.newTabForTesting()
        controller.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        drainMainQueue()

        let toast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 0))
        let armed = descendants(of: toast).compactMap { ($0 as? AppButton)?.keyEquivalent }
        XCTAssertEqual(armed, ["", ""], "a sticky toast arms no Return/Esc, keycap or not")
        XCTAssertFalse(toast.acceptsFirstResponder, "and it never takes focus from the terminal")
    }

    /// A sticky toast has no auto-dismiss, so one left up across a theme edit must recolor with the
    /// chrome — the `.configDidChange` fan-out re-themed the modal and the confirm toast but never
    /// the waiting ones, so the whole card (⌘N keycap included) stayed washed out until dismissed.
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

    /// The staleness the lazy resolve exists for: a toast is built once per notification, so one
    /// targeting tab 3 would keep reading "⌘3" after a tab before it closes and point at the wrong
    /// tab. Every tab mutation re-renders the tab bar, which re-resolves live toasts.
    func test_waitingToast_keycapFollowsItsTab_whenAnEarlierTabCloses() throws {
        let controller = makeController()
        controller.newTabForTesting()  // tab 2
        controller.newTabForTesting()  // tab 3
        controller.selectTabForTesting(index: 0)  // a waiting toast is for background tabs only
        controller.notifyAgentForTesting(tabIndex: 2, message: "needs your input")
        drainMainQueue()
        let toast = try XCTUnwrap(controller.waitingToastForTesting(tabIndex: 2))
        XCTAssertEqual(keycaps(in: toast), ["⌘3"])

        controller.closeTabForTesting(index: 0)  // the toast's tab is now the 2nd

        XCTAssertEqual(keycaps(in: toast), ["⌘2"], "the keycap must follow the tab, not go stale at ⌘3")
    }

    // MARK: command completion

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

    // MARK: the config-diagnostics toast

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

    /// The guarantee holds for the new `.primary` button too: a sticky toast never arms a
    /// Return/Esc equivalent, so it can't steal keys from the terminal.
    func test_configDiagnosticsToast_armsNoKeyEquivalents() {
        let controller = makeController()
        controller.showConfigDiagnosticsToast(
            ToastContent(variant: .warning, title: "t", message: "m"), landingScope: .keybindLine)
        let toast = toastViews(in: controller)[0]
        let armed = descendants(of: toast).compactMap { ($0 as? AppButton)?.keyEquivalent }
        XCTAssertEqual(armed, ["", ""], "a sticky toast arms no Return/Esc on either button")
        XCTAssertFalse(toast.acceptsFirstResponder, "and it never takes focus from the terminal")
    }

    /// The new seam end to end: firing the toast's "Open Settings" action opens the Settings card
    /// (the section it lands on is unit-tested via the scope→section map). A dead button would leave
    /// the toast's whole point unreachable.
    // MARK: conflict cards

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

    /// A float's `key:` is required, so there is nothing to back out to and the button must not be
    /// there. Offering it would promise an edit the app cannot make.
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

    /// A card whose write fails must stay up. It used to dismiss first and ignore the result, so an
    /// unwritable config read as a successful answer: the card slid away, nothing was written, and
    /// no error appeared anywhere.
    func test_conflictToast_aFailedWrite_leavesTheCardUp() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))
        // Make the config unwritable by putting a directory where the file belongs.
        let file = tempRoot.appendingPathComponent("config")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        try button("Accept", on: toastViews(in: controller)[0]).onTap()

        // Past the spring-out, or a card that IS dismissing still counts and the assertion holds
        // whether or not the fix is there.
        settle(1.0)
        XCTAssertEqual(toastViews(in: controller).count, 1, "the card stays, so it can be retried")
    }

    /// Answering one card must leave the others alone. Re-showing the reduced set used to spring
    /// every survivor out and a replacement in, which read on screen as the stack dropping a good
    /// way down and settling back.
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

    /// The other half: a set that grew keeps what is already up and adds beside it.
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

    /// The third exit. Answering writes; putting the card away must not, or a user tidying their
    /// screen would silently edit their config. Actionable toasts had no close affordance at all
    /// until this, so a conflict card could only be answered.
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

    /// The × is opt-in. It does nothing unless its host wires `onClose`, and only the conflict card
    /// does, so an actionable card that never asked for one must not draw a dead button. A confirm
    /// gates keyboard focus, so clicking a dead × there left the terminal deaf until Cancel was
    /// found.
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

    /// A passive toast has no buttons and dismisses on a body click, so a × there would be a second
    /// way to do the same thing on a card that needs none.
    func test_aPassiveToast_hasNoCloseAffordance() {
        let controller = makeController()
        controller.showToast(ToastContent(variant: .info, title: "t", message: "m"))

        let toast = toastViews(in: controller)[0]
        XCTAssertTrue(descendants(of: toast).compactMap { $0 as? IconButton }.isEmpty)
    }

    /// The card's buttons, end to end. Everything above asserts which buttons exist; this is the
    /// only thing checking that pressing one reaches the config. A card whose Accept did nothing
    /// would look completely correct and be the first surface a user meets.
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

    /// Answering takes that card down. Left up, it would describe a config that no longer exists.
    func test_conflictToast_answering_dismissesTheCard() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        let controller = makeController()
        controller.showConflictToasts(KeybindConflict.all(in: .current))

        try button("Accept", on: toastViews(in: controller)[0]).onTap()

        waitUntil(toastViews(in: controller).isEmpty, "the answered card comes down")
    }

    /// One card each. A list in a single card would let one Accept settle three decisions.
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

    /// The guarantee holds for these too: a sticky card never arms Return/Esc, so Esc keeps
    /// reaching the pane. It is why the × is the only keyboard-free way out of one.
    func test_conflictToast_armsNoKeyEquivalents() {
        let controller = makeController()
        controller.showConflictToasts([
            conflict(loser: .findNext, chord: Chord(command: true, key: "g"), winner: .splitVertical)
        ])

        let toast = toastViews(in: controller)[0]
        let armed = descendants(of: toast).compactMap { ($0 as? AppButton)?.keyEquivalent }
        XCTAssertEqual(armed, ["", ""], "neither button arms a key")
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

        // Dismissal springs out, so the cards leave the hierarchy a frame later.
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
        openButton.onTap()  // the action a click runs
        XCTAssertTrue(controller.isModalOverlayOpen, "Open Settings must open the Settings card")
    }
}
