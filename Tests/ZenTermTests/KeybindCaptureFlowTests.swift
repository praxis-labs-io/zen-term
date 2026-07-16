import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the keybind capture flow (ZEN-105): begin capture on a row, feed key
/// events through the real `KeybindCapturing` seam, and assert the rebind lands (or doesn't).
/// `resolve()` was tested; the capture / cancel / conflict / reset path — shipped in the last week
/// — was not, and a bug here bricks all keyboard input while recording.
///
/// The config write→reload roundtrip is sandboxed via `ConfigLoader.defaultRootOverrideForTesting`
/// so the tests never touch the real config. (Stacked on the ZEN-104 seam.)
final class KeybindCaptureFlowTests: XCTestCase {
    /// A `KeybindCapturing` double: stores the section's handler so a test can feed events, and
    /// counts `endCapture` so "still armed vs restored" is observable.
    private final class FakeCapturer: KeybindCapturing {
        private(set) var handler: ((NSEvent) -> Void)?
        private(set) var endCount = 0
        var isArmed: Bool { handler != nil }
        func beginCapture(_ handler: @escaping (NSEvent) -> Void) { self.handler = handler }
        func endCapture() { handler = nil; endCount += 1 }
        func feed(_ event: NSEvent) { handler?(event) }
    }

    private var tempRoot: URL!
    private var section: SettingsKeybindsSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-keybinds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()  // keymap == defaults (empty temp config)
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: event helpers

    private func keyDown(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: code)!
    }

    /// A `keyDown` matching a letter-key chord (keyCode 0 is fine — non-special keys decode from
    /// `charactersIgnoringModifiers`, not the code).
    private func event(for chord: Chord) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if chord.command { flags.insert(.command) }
        if chord.shift { flags.insert(.shift) }
        if chord.option { flags.insert(.option) }
        if chord.control { flags.insert(.control) }
        return keyDown(chord.key, code: 0, flags: flags)
    }

    /// A chord vanishingly unlikely to collide with any default: all four modifiers + a letter.
    private let novelChord = Chord(command: true, shift: true, option: true, control: true, key: "p")

    // MARK: harness

    private func mountSection(_ capturer: FakeCapturer) -> SettingsKeybindsSection {
        let section = SettingsKeybindsSection(capturer: capturer)
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        self.hostWindow = window
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        return section
    }

    /// Write a config into the sandboxed root and reload — for the cases that start from a config
    /// the user hand-wrote, rather than from the defaults.
    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func row(for action: KeyInterceptor.ReservedChord) -> KeybindRow {
        descendants(of: hostWindow!.contentView!).compactMap { $0 as? KeybindRow }
            .first { $0.action == action }!
    }

    private var liveKeymap: [Chord: KeyInterceptor.ReservedChord] { GeneralConfig.current.keymap }

    // MARK: tests

    func test_validChord_commitsRebindAndEndsCapture() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let oldChord = liveKeymap.first { $0.value == .newTab }!.key  // new-tab's chord before the rebind
        row(for: .newTab).chip.onActivate?()
        XCTAssertTrue(capturer.isArmed)

        capturer.feed(event(for: novelChord))

        XCTAssertEqual(liveKeymap[novelChord], .newTab, "the novel chord should now open a new tab")
        // A rebind is a MOVE, not an add: the old chord must be freed, else both would fire new-tab.
        XCTAssertNotEqual(liveKeymap[oldChord], .newTab, "the previous new-tab chord is released on rebind")
        XCTAssertEqual(capturer.endCount, 1, "a commit ends the capture")
        XCTAssertFalse(capturer.isArmed)
    }

    func test_esc_cancelsWithoutRebinding() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let before = liveKeymap
        row(for: .newTab).chip.onActivate?()

        capturer.feed(keyDown("\u{1b}", code: 53))  // Esc

        XCTAssertEqual(capturer.endCount, 1, "Esc ends the capture")
        XCTAssertFalse(capturer.isArmed)
        XCTAssertNil(liveKeymap[novelChord])
        XCTAssertEqual(liveKeymap, before, "Esc must not change any binding")
    }

    func test_delete_resetsReboundActionToDefault() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)

        // First rebind new-tab to the novel chord…
        row(for: .newTab).chip.onActivate?()
        capturer.feed(event(for: novelChord))
        XCTAssertEqual(liveKeymap[novelChord], .newTab)

        // …then capture again and press Delete → back to the built-in default(s).
        row(for: .newTab).chip.onActivate?()
        let endCountBeforeDelete = capturer.endCount
        capturer.feed(keyDown("\u{7f}", code: 51))  // Delete

        // Delete must END the capture, not just reset the mapping — leaving it armed is the
        // input-bricking scenario these tests guard against.
        XCTAssertEqual(capturer.endCount, endCountBeforeDelete + 1, "Delete ends the capture")
        XCTAssertFalse(capturer.isArmed)
        XCTAssertNil(liveKeymap[novelChord], "the reset drops the custom chord")
        let defaultNewTab = KeymapDefaults.map.first { $0.value == .newTab }!.key
        XCTAssertEqual(liveKeymap[defaultNewTab], .newTab, "new-tab is back on its default chord")
    }

    func test_conflictingChord_isBlockedAndStaysArmed() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        // A chord currently bound to a *different* action (new-tab).
        let newTabChord = liveKeymap.first { $0.value == .newTab }!.key
        let before = liveKeymap

        row(for: .closePane).chip.onActivate?()
        capturer.feed(event(for: newTabChord))

        XCTAssertTrue(capturer.isArmed, "a conflict keeps the capture armed for another try")
        XCTAssertEqual(capturer.endCount, 0)
        XCTAssertEqual(liveKeymap, before, "a conflicting chord must not rebind anything")
    }

    func test_modifierlessChord_isRejectedAndStaysArmed() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let before = liveKeymap

        row(for: .newTab).chip.onActivate?()
        capturer.feed(keyDown("k", code: 40))  // bare 'k', no modifiers

        XCTAssertTrue(capturer.isArmed, "a modifier-less chord is rejected but keeps waiting")
        XCTAssertEqual(capturer.endCount, 0)
        XCTAssertEqual(liveKeymap, before)
    }

    /// The safeguard at `WindowController.tearDown`: closing a window while a Settings capture is
    /// armed must end it — otherwise the shared interceptor stays in capture mode and swallows every
    /// keystroke in every other window.
    func test_windowClose_endsAnArmedCapture() {
        let originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        defer { TerminalSurfaceFactory.makeOverride = originalOverride }

        let capturer = FakeCapturer()
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), initialCWD: nil)
        controller.keybindCapturer = capturer
        capturer.beginCapture { _ in }  // arm it, as if a Settings row were recording
        XCTAssertTrue(capturer.isArmed)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertFalse(capturer.isArmed, "window close must end the armed capture")
        XCTAssertGreaterThanOrEqual(capturer.endCount, 1)
    }

    func test_capturingAnOccupiedChord_blocksAndLeavesTheOriginalBound() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let occupied = Chord(command: true, key: "t")  // New Tab's default
        XCTAssertEqual(liveKeymap[occupied], .newTab)

        row(for: .closePane).chip.onActivate?()
        capturer.feed(event(for: occupied))

        XCTAssertEqual(liveKeymap[occupied], .newTab, "the original action must keep its chord")
        XCTAssertNotEqual(liveKeymap[occupied], .closePane, "the occupied chord must not be taken")
        XCTAssertTrue(capturer.isArmed, "a blocked chord leaves capture armed")
        XCTAssertEqual(capturer.endCount, 0, "nothing was committed")
    }

    func test_resetToDefault_blocksWhenAnotherActionHoldsThatDefaultChord() {
        // Backspace-to-default is the one edit that picks its own chord, so it's the one that can
        // walk into an occupied one. Capture blocks on conflict; this must too, or restoring a
        // default silently evicts whatever the user deliberately put there.
        let capturer = FakeCapturer()
        _ = mountSection(capturer)

        row(for: .newTab).chip.onActivate?()  // move New Tab off ⌘T, freeing it
        capturer.feed(event(for: novelChord))
        let cmdT = Chord(command: true, key: "t")
        row(for: .closePane).chip.onActivate?()  // hand ⌘T to Close Pane
        capturer.feed(event(for: cmdT))
        XCTAssertEqual(liveKeymap[cmdT], .closePane)

        row(for: .newTab).chip.onActivate?()  // Backspace New Tab → its default ⌘T is taken
        capturer.feed(keyDown("\u{7f}", code: 51))

        XCTAssertEqual(liveKeymap[cmdT], .closePane, "restoring a default must not steal an occupied chord")
        XCTAssertEqual(liveKeymap[novelChord], .newTab, "and the blocked reset leaves New Tab as it was")
        let message = row(for: .newTab).renderedMessageForTesting
        XCTAssertNotNil(message, "a blocked reset has to say why")
        XCTAssertTrue(message?.contains("Close Pane") ?? false, message ?? "nil")
    }

    func test_resetToDefault_blocksWhenAFloatHoldsTheDefaultChord() throws {
        // The conflict check has to read the live keymap, not `desired` — `desired` excludes float
        // toggles, so checking there would miss a float sitting on the default chord entirely.
        try seed("float = id:steal command:btop key:cmd+t title:BTop\n")
        let capturer = FakeCapturer()
        _ = mountSection(capturer)

        row(for: .newTab).chip.onActivate?()
        capturer.feed(keyDown("\u{7f}", code: 51))  // Backspace → New Tab's default ⌘T, held by the float

        XCTAssertEqual(liveKeymap[Chord(command: true, key: "t")], .toggleToolFloat("steal"))
        XCTAssertTrue(row(for: .newTab).renderedMessageForTesting?.contains("BTop") ?? false)
    }

    func test_capturingAnOccupiedShiftedSymbol_blocks() {
        // The ZEN-142 shape: ⌘⇧- arrives as "_" and must still be recognized as taken.
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .closePane).chip.onActivate?()

        capturer.feed(keyDown("_", code: 0, flags: [.command, .shift]))

        XCTAssertEqual(liveKeymap[Chord(command: true, shift: true, key: "-")], .splitHorizontal)
        XCTAssertTrue(capturer.isArmed, "an occupied shifted-symbol chord must block too")
    }

    // MARK: conflict surface (ZEN-142)

    func test_floatStealingAnActionsChord_showsTheReasonOnTheRow() throws {
        // A float's `key:` silently wins over a built-in. Before ZEN-142 the New Tab row just
        // rendered an empty chip — no chip, no reason, nothing to act on.
        try seed("float = id:steal command:btop key:cmd+t\n")
        _ = mountSection(FakeCapturer())

        let newTab = row(for: .newTab)
        XCTAssertNil(newTab.chip.renderedShortcutForTesting, "the stolen chord leaves the chip unbound")
        let message = try XCTUnwrap(newTab.renderedMessageForTesting, "the row must say why it has no shortcut")
        XCTAssertTrue(message.contains("⌘T"), message)
        XCTAssertTrue(message.contains("toggle_float:steal"), message)
    }

    func test_rowsWithoutAConflict_showNoMessage() throws {
        try seed("float = id:steal command:btop key:cmd+t\n")
        _ = mountSection(FakeCapturer())
        // The guard has to stay quiet everywhere it doesn't apply, or it's noise.
        XCTAssertNil(row(for: .closePane).renderedMessageForTesting)
        XCTAssertNil(row(for: .splitVertical).renderedMessageForTesting)
    }

    func test_configReload_updatesRowsOfAnOpenCard() throws {
        try seed("float = id:steal command:btop key:cmd+t\n")
        _ = mountSection(FakeCapturer())
        XCTAssertNotNil(row(for: .newTab).renderedMessageForTesting)

        // Fixing the config is exactly what ⌘⌥R follows, so an open card has to notice.
        try seed("")

        let drained = expectation(description: "main queue drained")  // observer runs on OperationQueue.main
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertNil(row(for: .newTab).renderedMessageForTesting, "the resolved conflict must clear")
        XCTAssertEqual(row(for: .newTab).chip.renderedShortcutForTesting, "⌘T", "and the chord comes back")
    }

    func test_reloadDuringCapture_isDeferred_soALaterWriteKeepsItsLines() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .closePane).chip.onActivate?()  // arm a capture

        // A hand-edit + reload lands mid-capture (another window's ⌘⌥R).
        try seed("keybind = nav_left=cmd+opt+h\n")
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        capturer.feed(keyDown("\u{1b}", code: 53))  // Esc → capture ends, the deferred reload replays

        // Now edit an unrelated row. `ConfigWriter` regenerates the WHOLE keybind block from
        // `desired`, so if the reload was dropped rather than deferred, `desired` never learned about
        // nav_left and this write silently deletes the user's hand-written line.
        row(for: .newTab).chip.onActivate?()
        capturer.feed(event(for: novelChord))

        let text = try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(text.contains("nav_left=cmd+opt+h"), "an unrelated rebind must not delete it:\n\(text)")
        XCTAssertEqual(liveKeymap[Chord(command: true, option: true, key: "h")], .navLeft)
    }

    func test_reloadDuringCapture_isRebasedBeforeACommittedRebindWrites() throws {
        // The sibling test presses Esc, which routes through hideHint's replay. COMMITTING the
        // capture instead writes 0.7s BEFORE that timer fires, so the replay is too late — the edit
        // has to be layered on the reloaded set at commit time, not after.
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .closePane).chip.onActivate?()  // arm a capture

        try seed("keybind = nav_left=cmd+opt+h\n")  // a foreign reload lands mid-capture
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        capturer.feed(event(for: novelChord))  // commit, rather than cancel

        let text = try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(text.contains("nav_left=cmd+opt+h"), "a committed rebind must not delete it:\n\(text)")
        XCTAssertEqual(liveKeymap[Chord(command: true, option: true, key: "h")], .navLeft)
        XCTAssertEqual(liveKeymap[novelChord], .closePane, "and the rebind itself still lands")
    }

    func test_blockedReset_messageClearsOnceTheChordIsFreed() throws {
        // The block is transient feedback, not a failed write: a reload that frees the chord is
        // exactly what resolves it, so the row must stop insisting the chord is taken.
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .newTab).chip.onActivate?()
        capturer.feed(event(for: novelChord))  // free ⌘T
        row(for: .closePane).chip.onActivate?()
        capturer.feed(event(for: Chord(command: true, key: "t")))  // Close Pane takes ⌘T

        row(for: .newTab).chip.onActivate?()
        capturer.feed(keyDown("\u{7f}", code: 51))  // Backspace → blocked
        XCTAssertEqual(row(for: .newTab).messageKind, .blocked)

        // Free ⌘T by hand and reload.
        try seed("keybind = new_tab=cmd+shift+opt+ctrl+p\n")
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertNil(
            row(for: .newTab).renderedMessageForTesting,
            "the block must not outlive the conflict it describes")
    }

    func test_configDiagnosticMessage_readsAsAWarningNotAFailure() throws {
        // A config that works but surprises isn't the same as a write that failed; rendering both in
        // destructive red teaches the user to read a working config as breakage.
        try seed("float = id:steal command:btop key:cmd+t\n")
        _ = mountSection(FakeCapturer())
        XCTAssertEqual(row(for: .newTab).messageKind, .diagnostic)
    }

    func test_splitRows_showTheBaseKeyGlyph() {
        // Display ≡ config token: the chip shows what you'd type into the file (ZEN-142).
        _ = mountSection(FakeCapturer())
        XCTAssertEqual(row(for: .splitHorizontal).chip.renderedShortcutForTesting, "⌘⇧-")
        XCTAssertEqual(row(for: .splitVertical).chip.renderedShortcutForTesting, "⌘⇧\\")
    }
}
