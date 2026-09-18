import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class KeybindCaptureFlowTests: WindowTestCase {
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
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigReset.toBuiltIn()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func keyDown(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: code)!
    }

    private func event(for chord: Chord) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if chord.command { flags.insert(.command) }
        if chord.shift { flags.insert(.shift) }
        if chord.option { flags.insert(.option) }
        if chord.control { flags.insert(.control) }
        return keyDown(chord.key, code: 0, flags: flags)
    }

    private let novelChord = Chord(command: true, shift: true, option: true, control: true, key: "p")

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

    func test_validChord_commitsRebindAndEndsCapture() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let oldChord = liveKeymap.first { $0.value == .newTab }!.key
        row(for: .newTab).chip.onActivate?()
        XCTAssertTrue(capturer.isArmed)

        capturer.feed(event(for: novelChord))

        XCTAssertEqual(liveKeymap[novelChord], .newTab, "the novel chord should now open a new tab")
        XCTAssertNotEqual(liveKeymap[oldChord], .newTab, "the previous new-tab chord is released on rebind")
        XCTAssertEqual(capturer.endCount, 1, "a commit ends the capture")
        XCTAssertFalse(capturer.isArmed)
    }

    func test_scratchFloat_rebindsThroughTheRealRow_andWritesTheLine() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let scratch = KeyInterceptor.ReservedChord.toggleToolFloat(ToolFloat.scratch.id)
        row(for: scratch).chip.onActivate?()

        capturer.feed(event(for: novelChord))

        XCTAssertEqual(liveKeymap[novelChord], scratch, "the novel chord should now open Scratch")
        XCTAssertNil(liveKeymap[Chord(command: true, key: ";")], "the default is released on rebind")
        let text = try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(
            text.contains("keybind = toggle_float:scratch="),
            "the rebind has nowhere else to live: \(text)")
    }

    func test_esc_cancelsWithoutRebinding() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let before = liveKeymap
        row(for: .newTab).chip.onActivate?()

        capturer.feed(keyDown("\u{1b}", code: 53))

        XCTAssertEqual(capturer.endCount, 1, "Esc ends the capture")
        XCTAssertFalse(capturer.isArmed)
        XCTAssertNil(liveKeymap[novelChord])
        XCTAssertEqual(liveKeymap, before, "Esc must not change any binding")
    }

    func test_delete_leavesTheActionWithNoShortcut() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .newTab).chip.onActivate?()
        let endCountBefore = capturer.endCount

        capturer.feed(deleteKey(option: false))

        XCTAssertEqual(capturer.endCount, endCountBefore + 1, "Delete ends the capture")
        XCTAssertFalse(capturer.isArmed)
        XCTAssertFalse(liveKeymap.values.contains(.newTab))
        XCTAssertEqual(GeneralConfig.current.unboundActions, [.newTab])
        let text = try configText()
        XCTAssertTrue(text.contains("keybind = new_tab=none"), text)
    }

    func test_conflictingChord_isBlockedAndStaysArmed() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
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
        capturer.feed(keyDown("k", code: 40))

        XCTAssertTrue(capturer.isArmed, "a modifier-less chord is rejected but keeps waiting")
        XCTAssertEqual(capturer.endCount, 0)
        XCTAssertEqual(liveKeymap, before)
    }

    func test_windowClose_endsAnArmedCapture() {
        let originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        defer { TerminalSurfaceFactory.makeOverride = originalOverride }

        let capturer = FakeCapturer()
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), initialCWD: nil)
        controller.keybindCapturer = capturer
        capturer.beginCapture { _ in }
        XCTAssertTrue(capturer.isArmed)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertFalse(capturer.isArmed, "window close must end the armed capture")
        XCTAssertGreaterThanOrEqual(capturer.endCount, 1)
    }

    func test_capturingAnOccupiedChord_blocksAndLeavesTheOriginalBound() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let occupied = Chord(command: true, key: "t")
        XCTAssertEqual(liveKeymap[occupied], .newTab)

        row(for: .closePane).chip.onActivate?()
        capturer.feed(event(for: occupied))

        XCTAssertEqual(liveKeymap[occupied], .newTab, "the original action must keep its chord")
        XCTAssertNotEqual(liveKeymap[occupied], .closePane, "the occupied chord must not be taken")
        XCTAssertTrue(capturer.isArmed, "a blocked chord leaves capture armed")
        XCTAssertEqual(capturer.endCount, 0, "nothing was committed")
    }

    func test_resetToDefault_takesAnOccupiedChordButSaysWhatItDisplaced() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)

        row(for: .newTab).chip.onActivate?()
        capturer.feed(event(for: novelChord))
        let cmdT = Chord(command: true, key: "t")
        row(for: .closePane).chip.onActivate?()
        capturer.feed(event(for: cmdT))
        XCTAssertEqual(liveKeymap[cmdT], .closePane)

        row(for: .newTab).chip.onActivate?()
        try resetIcon().onClick()

        XCTAssertEqual(liveKeymap[cmdT], .newTab, "the default is restored")
        XCTAssertEqual(liveKeymap[Chord(command: true, key: "w")], .closePane, "the displaced action falls back")
        let message = row(for: .closePane).renderedMessageForTesting
        XCTAssertNotNil(message, "the displaced row must say it lost its chord")
        XCTAssertTrue(message?.contains("⌘T") ?? false, message ?? "nil")
        XCTAssertTrue(message?.contains("New Tab") ?? false, message ?? "nil")
        XCTAssertEqual(row(for: .closePane).messageKind, .notice)
    }

    func test_resetToDefault_swappedPair_canBeRevertedOneRowAtATime() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let cmdT = Chord(command: true, key: "t")
        let cmdN = Chord(command: true, key: "n")

        row(for: .newWindow).chip.onActivate?()
        capturer.feed(event(for: novelChord))
        row(for: .newTab).chip.onActivate?()
        capturer.feed(event(for: cmdN))
        row(for: .newWindow).chip.onActivate?()
        capturer.feed(event(for: cmdT))
        XCTAssertEqual(liveKeymap[cmdT], .newWindow)
        XCTAssertEqual(liveKeymap[cmdN], .newTab)

        row(for: .newTab).chip.onActivate?()
        try resetIcon().onClick()

        XCTAssertEqual(liveKeymap[cmdT], .newTab, "New Tab is back on its default")
        XCTAssertEqual(liveKeymap[cmdN], .newWindow, "and New Window lands on its default too")
    }

    func test_capturingAnOccupiedShiftedSymbol_blocks() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .closePane).chip.onActivate?()

        capturer.feed(keyDown("+", code: 0, flags: [.command, .shift]))

        XCTAssertEqual(liveKeymap[Chord(command: true, shift: true, key: "=")], .increaseFontSize)
        XCTAssertTrue(capturer.isArmed, "an occupied shifted-symbol chord must block too")
    }

    private func deleteKey(option: Bool) -> NSEvent {
        keyDown("\u{7f}", code: 51, flags: option ? [.option] : [])
    }

    func test_delete_onAFocusedChip_leavesTheActionWithNoShortcut() throws {
        _ = mountSection(FakeCapturer())
        let newTab = row(for: .newTab)

        newTab.chip.keyDown(with: deleteKey(option: false))

        XCTAssertNil(newTab.chip.renderedShortcutForTesting, "the chip reads as unbound")
        XCTAssertNil(newTab.renderedMessageForTesting, "an unbind the user asked for needs no note")
        XCTAssertFalse(liveKeymap.values.contains(.newTab))
        XCTAssertEqual(GeneralConfig.current.unboundActions, [.newTab])
        let text = try configText()
        XCTAssertTrue(text.contains("keybind = new_tab=none"), text)
    }

    func test_optionDelete_recordsAChordRatherThanClearingTheAction() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .removeWorktree).chip.onActivate?()

        capturer.feed(deleteKey(option: true))

        XCTAssertEqual(liveKeymap[Chord(option: true, key: "⌫")], .removeWorktree)
        XCTAssertEqual(GeneralConfig.current.unboundActions, [], "⌥⌫ is a chord, never the clear")
        XCTAssertFalse(capturer.isArmed, "recording it ends the capture")
    }

    func test_optionForwardDelete_clearsRatherThanRecording() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .newTab).chip.onActivate?()

        capturer.feed(keyDown("\u{f728}", code: 117, flags: [.option]))

        XCTAssertEqual(GeneralConfig.current.unboundActions, [.newTab], "⌦ clears, never records")
        let text = try configText()
        XCTAssertFalse(text.contains("\u{f728}"), "no unprintable key reaches the file: \(text)")
    }

    func test_theResetButton_putsTheDefaultBack() throws {
        _ = mountSection(FakeCapturer())
        row(for: .newTab).chip.keyDown(with: deleteKey(option: false))
        XCTAssertFalse(liveKeymap.values.contains(.newTab))

        row(for: .newTab).chip.onActivate?()
        try resetIcon().onClick()

        let defaultChord = KeymapDefaults.map.first { $0.value == .newTab }!.key
        XCTAssertEqual(liveKeymap[defaultChord], .newTab)
        XCTAssertEqual(GeneralConfig.current.unboundActions, [])
        let text = try configText()
        XCTAssertFalse(text.contains("new_tab"), text)
    }

    func test_theResetButton_endsTheCapture() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .newTab).chip.onActivate?()
        XCTAssertTrue(capturer.isArmed)

        try resetIcon().onClick()

        XCTAssertFalse(capturer.isArmed)
        XCTAssertEqual(capturer.endCount, 1)
    }

    func test_removingThenCapturingAChord_bindsItAndDropsTheNoneLine() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .newTab).chip.keyDown(with: deleteKey(option: false))

        row(for: .newTab).chip.onActivate?()
        capturer.feed(event(for: novelChord))

        XCTAssertEqual(liveKeymap[novelChord], .newTab)
        XCTAssertEqual(GeneralConfig.current.unboundActions, [])
    }

    private func configText() throws -> String {
        try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
    }

    private func hintBubble() throws -> KeybindHintBubble {
        try XCTUnwrap(descendants(of: hostWindow!.contentView!).compactMap { $0 as? KeybindHintBubble }.first)
    }

    private func resetIcon() throws -> IconButton {
        try XCTUnwrap(descendants(of: try hintBubble()).compactMap { $0 as? IconButton }.first)
    }

    private func hintText() throws -> String {
        descendants(of: try hintBubble()).compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: " ")
    }

    func test_resetIcon_isHiddenWhenAFloatTookTheChord() throws {
        try seed("float = title:lazygit command:lazygit key:cmd+g\n")
        _ = mountSection(FakeCapturer())

        row(for: .findNext).chip.onActivate?()

        XCTAssertTrue(try resetIcon().isHidden, "nothing to back out of, so nothing to offer")
    }

    func test_theInputFillsTheCard() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let insets: CGFloat = 28

        row(for: .newTab).chip.onActivate?()
        try hintBubble().layoutSubtreeIfNeeded()
        XCTAssertEqual(
            try hintBubble().inputWidthForTesting, KeybindHintBubble.widthForTesting - insets,
            accuracy: 0.5, "no reset icon, so the input takes the whole row")

        capturer.feed(event(for: novelChord))
        row(for: .newTab).chip.onActivate?()
        try hintBubble().layoutSubtreeIfNeeded()
        XCTAssertEqual(
            try hintBubble().inputWidthForTesting,
            KeybindHintBubble.widthForTesting - insets - 34 - 8,
            accuracy: 0.5, "and gives up exactly the icon's width when one appears")
    }

    func test_resetIcon_isShownWhenAKeybindLineTookTheChord() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        _ = mountSection(FakeCapturer())

        row(for: .toggleCommandPalette).chip.onActivate?()

        XCTAssertFalse(try resetIcon().isHidden)
    }

    func test_theHint_readsTheSameOnEveryRow() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        _ = mountSection(FakeCapturer())

        row(for: .toggleCommandPalette).chip.onActivate?()
        let conflicted = try hintText()
        XCTAssertTrue(conflicted.contains("to cancel"), conflicted)
        XCTAssertTrue(conflicted.contains("to remove"), conflicted)
    }

    func test_resetIcon_appearsOnlyWhenTheRowIsOffItsDefault() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)

        row(for: .newTab).chip.onActivate?()
        XCTAssertTrue(try resetIcon().isHidden, "a row at its default has nothing to reset to")
        capturer.feed(event(for: novelChord))

        row(for: .newTab).chip.onActivate?()
        XCTAssertFalse(try resetIcon().isHidden, "rebound, so there is a default to go back to")
    }

    func test_resetIcon_isShownForARemovedShortcut() throws {
        _ = mountSection(FakeCapturer())
        row(for: .newTab).chip.keyDown(with: deleteKey(option: false))

        row(for: .newTab).chip.onActivate?()

        XCTAssertFalse(try resetIcon().isHidden, "removed is off the default too, so it can come back")
    }

    func test_aRefusedChord_returnsTheInputToListening() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let newTabChord = liveKeymap.first { $0.value == .newTab }!.key

        row(for: .closePane).chip.onActivate?()
        capturer.feed(event(for: newTabChord))

        XCTAssertNil(
            try hintBubble().previewedChordForTesting,
            "the input is back to Press keys…, not sitting on what was refused")
        XCTAssertTrue(capturer.isArmed, "and it is still listening")
    }

    func test_aModifierlessKey_alsoReturnsTheInputToListening() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)

        row(for: .closePane).chip.onActivate?()
        capturer.feed(keyDown("k", code: 40))

        XCTAssertNil(try hintBubble().previewedChordForTesting)
        XCTAssertTrue(capturer.isArmed)
    }

    func test_aConflictedRow_explainsItselfInNeutralInk() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        _ = mountSection(FakeCapturer())

        let row = row(for: .toggleCommandPalette)
        XCTAssertNil(row.chip.renderedShortcutForTesting)
        XCTAssertEqual(row.renderedMessageForTesting, "⌘⇧P goes to split_vertical.")
        XCTAssertEqual(row.messageKind, .explanation, "neutral: the config did what it says")
    }

    func test_deleteOnAConflictedRow_settlesIt() throws {
        try seed("keybind = split_vertical=cmd+shift+p\n")
        _ = mountSection(FakeCapturer())

        row(for: .toggleCommandPalette).chip.keyDown(with: deleteKey(option: false))

        XCTAssertEqual(GeneralConfig.current.unboundActions, [.toggleCommandPalette])
        XCTAssertEqual(KeybindConflict.all(in: .current), [], "nothing reports it again")
        XCTAssertNil(row(for: .toggleCommandPalette).renderedMessageForTesting, "and the row goes quiet")
        let text = try configText()
        XCTAssertTrue(text.contains("keybind = toggle_command_palette=none"), text)
    }

    func test_aCleanRow_showsNoMessage() {
        _ = mountSection(FakeCapturer())

        XCTAssertNil(row(for: .toggleCommandPalette).renderedMessageForTesting)
    }

    func test_floatStealingAnActionsChord_showsTheReasonOnTheRow() throws {
        try seed("float = title:steal command:btop key:cmd+t\n")
        _ = mountSection(FakeCapturer())

        let newTab = row(for: .newTab)
        XCTAssertNil(newTab.chip.renderedShortcutForTesting, "the stolen chord leaves the chip unbound")
        let message = try XCTUnwrap(newTab.renderedMessageForTesting, "the row must say why it has no shortcut")
        XCTAssertTrue(message.contains("⌘T"), message)
        XCTAssertTrue(message.contains("toggle_float:steal"), message)
    }

    func test_rowsWithoutAConflict_showNoMessage() throws {
        try seed("float = title:steal command:btop key:cmd+t\n")
        _ = mountSection(FakeCapturer())
        XCTAssertNil(row(for: .closePane).renderedMessageForTesting)
        XCTAssertNil(row(for: .splitVertical).renderedMessageForTesting)
    }

    func test_configReload_updatesRowsOfAnOpenCard() throws {
        try seed("float = title:steal command:btop key:cmd+t\n")
        _ = mountSection(FakeCapturer())
        XCTAssertNotNil(row(for: .newTab).renderedMessageForTesting)

        try seed("")

        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertNil(row(for: .newTab).renderedMessageForTesting, "the resolved conflict must clear")
        XCTAssertEqual(row(for: .newTab).chip.renderedShortcutForTesting, "⌘T", "and the chord comes back")
    }

    func test_reloadDuringCapture_isDeferred_soALaterWriteKeepsItsLines() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .closePane).chip.onActivate?()

        try seed("keybind = nav_left=cmd+opt+h\n")
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        capturer.feed(keyDown("\u{1b}", code: 53))

        row(for: .newTab).chip.onActivate?()
        capturer.feed(event(for: novelChord))

        let text = try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(text.contains("nav_left=cmd+opt+h"), "an unrelated rebind must not delete it:\n\(text)")
        XCTAssertEqual(liveKeymap[Chord(command: true, option: true, key: "h")], .navLeft)
    }

    func test_reloadDuringCapture_isRebasedBeforeACommittedRebindWrites() throws {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        row(for: .closePane).chip.onActivate?()

        try seed("keybind = nav_left=cmd+opt+h\n")
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        capturer.feed(event(for: novelChord))

        let text = try String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(text.contains("nav_left=cmd+opt+h"), "a committed rebind must not delete it:\n\(text)")
        XCTAssertEqual(liveKeymap[Chord(command: true, option: true, key: "h")], .navLeft)
        XCTAssertEqual(liveKeymap[novelChord], .closePane, "and the rebind itself still lands")
    }

    func test_aChordTakenByAFloat_readsAsAnExplanation() throws {
        try seed("float = title:steal command:btop key:cmd+t\n")
        _ = mountSection(FakeCapturer())
        XCTAssertEqual(row(for: .newTab).messageKind, .explanation)
        XCTAssertEqual(row(for: .newTab).renderedMessageForTesting, "⌘T goes to toggle_float:steal.")
    }

    func test_theChips_nameTheMovedChords() {
        _ = mountSection(FakeCapturer())
        XCTAssertEqual(row(for: .navUp).chip.renderedShortcutForTesting, "⌘⌥↑")
        XCTAssertEqual(row(for: .resizeLeft).chip.renderedShortcutForTesting, "⌘⌃←")
        XCTAssertEqual(row(for: .toggleSearch).chip.renderedShortcutForTesting, "⌘F")
        XCTAssertEqual(row(for: .fillScreen).chip.renderedShortcutForTesting, "⌘⏎")
        XCTAssertEqual(row(for: .scrollToSelection).chip.renderedShortcutForTesting, "⌘J")
    }

    func test_aRebindMovesTheChip_offTheDefault() throws {
        try seed("keybind = resize_left=cmd+shift+opt+y\n")
        _ = mountSection(FakeCapturer())
        XCTAssertEqual(row(for: .resizeLeft).chip.renderedShortcutForTesting, "⌘⇧⌥Y")
    }
}
