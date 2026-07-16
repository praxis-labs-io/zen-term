import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the tool-float add / edit form (ZEN-109): drive the real fields + chord
/// chip in a window and assert the built `ToolFloat` (or that an invalid form is blocked). A
/// state-only test would pass while the form's controls were dead — exactly the failure mode the
/// project's interaction-test rule guards against.
final class ToolFloatFormOverlayTests: XCTestCase {
    /// A `KeybindCapturing` double: stores the form's handler so a test can feed a chord event.
    private final class FakeCapturer: KeybindCapturing {
        private(set) var handler: ((NSEvent) -> Void)?
        var isArmed: Bool { handler != nil }
        func beginCapture(_ handler: @escaping (NSEvent) -> Void) { self.handler = handler }
        func endCapture() { handler = nil }
        func feed(_ event: NSEvent) { handler?(event) }
    }

    /// Captures what the form hands back, so the closures can record across the test.
    private final class Sink {
        var submitted: [ToolFloat] = []
        var cancelled = 0
        var deleted = 0
    }

    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    // MARK: harness

    private let novelChord = Chord(command: true, shift: true, option: true, control: true, key: "p")

    private func keyDown(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func event(for chord: Chord) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if chord.command { flags.insert(.command) }
        if chord.shift { flags.insert(.shift) }
        if chord.option { flags.insert(.option) }
        if chord.control { flags.insert(.control) }
        return keyDown(chord.key, code: 0, flags: flags)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mount(
        editing: ToolFloat? = nil, existingIDs: Set<String> = [], withDelete: Bool = false
    ) -> (overlay: ToolFloatFormOverlay, capturer: FakeCapturer, sink: Sink) {
        let capturer = FakeCapturer()
        let sink = Sink()
        let overlay = ToolFloatFormOverlay(
            editing: editing, existingIDs: existingIDs, capturer: capturer,
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { sink.submitted.append($0) },
            onCancel: { sink.cancelled += 1 },
            onDelete: withDelete ? { sink.deleted += 1 } : nil)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        window = win
        return (overlay, capturer, sink)
    }

    private func field(in overlay: NSView, placeholder: String) -> FieldBox {
        descendants(of: overlay).compactMap { $0 as? FieldBox }.first { $0.placeholder == placeholder }!
    }

    /// A segmented control found by its first option's title — the form has two of them.
    private func segment(in overlay: NSView, firstOption: String) -> SegmentedControl {
        descendants(of: overlay).compactMap { $0 as? SegmentedControl }
            .first { $0.optionTitles.first == firstOption }!
    }

    private func chip(in overlay: NSView) -> KeybindChip {
        descendants(of: overlay).compactMap { $0 as? KeybindChip }.first!
    }

    /// Record a chord through the form's real capture path: arm the chip, then feed the event.
    private func capture(_ chord: Chord, in overlay: NSView, _ capturer: FakeCapturer) {
        chip(in: overlay).onActivate?()
        XCTAssertTrue(capturer.isArmed, "activating the chip should arm capture")
        capturer.feed(event(for: chord))
    }

    /// Submit via ⌘Return in the command field — the form's real submit path.
    private func submit(in overlay: NSView) {
        field(in: overlay, placeholder: "npm run dev").onSubmit?()
    }

    // MARK: tests

    func test_cardFillsAvailableWidth() {
        let (overlay, _, _) = mount()  // host window is 480 wide
        overlay.frame = overlay.superview!.bounds
        overlay.layoutSubtreeIfNeeded()
        // The card is 460 (clamped to 0.92× a 480 host), so a full-width field should be ~400, not
        // collapsed to its intrinsic content. Guards the "form is super narrow" regression.
        let idField = field(in: overlay, placeholder: "gitdash")
        XCTAssertGreaterThan(idField.frame.width, 300, "form fields should fill the card, not collapse")
    }

    func test_fillAndSubmit_buildsFloatFromControls() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("npm run dev")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.count, 1)
        let float = sink.submitted.first
        XCTAssertEqual(float?.id, "dev")
        XCTAssertEqual(float?.command, "npm run dev")
        XCTAssertEqual(float?.toggle, novelChord)
        XCTAssertEqual(float?.title, "Open dev")  // blank title → derived default
        XCTAssertEqual(float?.icon, ToolFloatParser.defaultIcon)
        XCTAssertEqual(float?.widthFraction, ToolFloatParser.defaultFraction)
        XCTAssertEqual(float?.requiresGitRepo, false)
    }

    func test_shortcutCapture_showsSharedKeybindPopover() {
        let (overlay, capturer, _) = mount()
        descendants(of: overlay).compactMap { $0 as? KeybindChip }.first?.onActivate?()
        XCTAssertTrue(capturer.isArmed)
        let bubble = descendants(of: overlay).compactMap { $0 as? KeybindHintBubble }.first
        XCTAssertNotNil(bubble, "arming the shortcut capture shows the shared Keybinds popover")
    }

    func test_missingChord_blocksSubmit() {
        let (overlay, _, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "no shortcut → submit is blocked")
    }

    func test_emptyCommand_blocksSubmit() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("dev")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "empty command → submit is blocked")
    }

    func test_titleWithQuote_blocksSubmit() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        field(in: overlay, placeholder: "Open GitDash").setText("Say \" hi")  // a `"` can't round-trip
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a title with a \" is rejected, so submit is blocked")
    }

    func test_conflictingShortcut_isRejected() throws {
        // Sandbox a config that already binds ⌘⇧G to an existing float.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-floatconflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        defer {
            ConfigLoader.defaultRootOverrideForTesting = nil
            AppConfig.reload()
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try "float = id:existing command:htop key:cmd+shift+g\n"
            .write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        let (overlay, capturer, sink) = mount()  // a new float
        field(in: overlay, placeholder: "gitdash").setText("new")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(Chord(command: true, shift: true, key: "g"), in: overlay, capturer)  // conflicts

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a shortcut already in use is rejected, so submit is blocked")
    }

    func test_duplicateID_blocksSubmit() {
        let (overlay, capturer, sink) = mount(existingIDs: ["dev"])
        field(in: overlay, placeholder: "gitdash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "an id already in use → submit is blocked")
    }

    func test_iconPicker_pickFromGrid_appliesToBuiltFloat() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        let picker = descendants(of: overlay).compactMap { $0 as? IconPickerField }.first!
        XCTAssertEqual(picker.selected, IconCatalog.defaultSymbol)
        picker.openForTesting()
        XCTAssertTrue(picker.isPopoverOpenForTesting)
        picker.moveHighlightForTesting(1)  // default (index 0) → the next curated icon
        picker.commitHighlightForTesting()
        XCTAssertFalse(picker.isPopoverOpenForTesting, "committing closes the grid")
        XCTAssertEqual(picker.selected, IconCatalog.all[1])

        submit(in: overlay)
        XCTAssertEqual(sink.submitted.first?.icon, IconCatalog.all[1])
    }

    func test_editForm_deleteButton_firesOnDelete() {
        let existing = ToolFloat(
            id: "dev", title: "Open dev", icon: IconCatalog.defaultSymbol, command: "vim", dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "d"))
        let (overlay, _, sink) = mount(editing: existing, withDelete: true)
        let delete = descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Delete" }
        XCTAssertNotNil(delete, "editing an existing float shows a Delete button")

        delete?.onTap()

        XCTAssertEqual(sink.deleted, 1)
    }

    func test_addForm_hasNoDeleteButton() {
        let (overlay, _, _) = mount()  // add mode
        let delete = descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Delete" }
        XCTAssertNil(delete, "adding a new float has no Delete button")
    }

    func test_edit_prefillsAndSavesChangedCommand() {
        let existing = ToolFloat(
            id: "dev", title: "Open dev", icon: ToolFloatParser.defaultIcon, command: "vim", dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "d"))
        let (overlay, _, sink) = mount(editing: existing)

        XCTAssertEqual(field(in: overlay, placeholder: "gitdash").text, "dev")
        XCTAssertEqual(field(in: overlay, placeholder: "npm run dev").text, "vim")

        field(in: overlay, placeholder: "npm run dev").setText("nvim")
        submit(in: overlay)  // chord already prefilled — no capture needed

        XCTAssertEqual(sink.submitted.count, 1)
        XCTAssertEqual(sink.submitted.first?.id, "dev")
        XCTAssertEqual(sink.submitted.first?.command, "nvim")
        XCTAssertEqual(sink.submitted.first?.toggle, Chord(command: true, shift: true, key: "d"))
    }

    func test_persistSegment_defaultsToEphemeral_andBuildsTheChosenMode() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("lg")
        field(in: overlay, placeholder: "npm run dev").setText("lazygit")
        capture(novelChord, in: overlay, capturer)

        segment(in: overlay, firstOption: "Fresh each time").select(1)  // Per directory
        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.persist, .directory)
    }

    func test_persistSegment_untouched_buildsEphemeral() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("y")
        field(in: overlay, placeholder: "npm run dev").setText("yazi")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.persist, .ephemeral)
    }

    func test_dirField_buildsPinnedDirectory() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("notes")
        field(in: overlay, placeholder: "npm run dev").setText("nvim")
        field(in: overlay, placeholder: "~/notes").setText("~/notes")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.dir?.path, NSString(string: "~/notes").expandingTildeInPath)
    }

    func test_blankDirField_buildsNilDirectory() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "gitdash").setText("y")
        field(in: overlay, placeholder: "npm run dev").setText("yazi")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertNil(sink.submitted.first?.dir)
    }

    /// Editing a float must not silently flatten fields the form didn't previously expose.
    func test_edit_prefillsPersistAndDir() {
        let existing = ToolFloat(
            id: "lg", title: "Open Lazygit", icon: "git", command: "lazygit",
            dir: URL(fileURLWithPath: "/tmp/x"), widthFraction: 0.85, heightFraction: 0.78,
            requiresGitRepo: true, persist: .tab, toggle: Chord(command: true, key: "g"))
        let (overlay, _, sink) = mount(editing: existing)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.persist, .tab)
        XCTAssertEqual(sink.submitted.first?.dir?.path, "/tmp/x")
    }

    /// `/tmp/x` above is outside `$HOME`, so `abbreviatingHome` is a no-op on it and can't tell a
    /// correct re-abbreviate from a raw `dir.path` regression. Use a home-relative fixture instead,
    /// and touch only an unrelated field — the real scenario of an untouched `dir` surviving submit.
    ///
    /// Note this asserts the *prefilled field text*, not just the submitted float's `dir?.path`:
    /// `ToolFloat.dir` is a `URL`, so `.path` is always the absolute form, and `buildFloat`'s
    /// `expandingTildeInPath` is a no-op on an already-absolute string — so an absolute-path
    /// regression in `prefill()` still round-trips to the identical submitted `dir?.path`. The
    /// abbreviation is only observable in what the field displays, which is what a user actually sees
    /// and re-saves; that's the assertion that would fail if `prefill()` regressed to raw `dir.path`.
    func test_edit_untouchedHomeRelativeDir_prefillsAbbreviatedAndRoundTripsOnSubmit() {
        let homeRelativePath = PathDisplay.homePath + "/notes"
        let existing = ToolFloat(
            id: "lg", title: "Open Lazygit", icon: "git", command: "lazygit",
            dir: URL(fileURLWithPath: homeRelativePath), widthFraction: 0.85, heightFraction: 0.78,
            requiresGitRepo: true, persist: .tab, toggle: Chord(command: true, key: "g"))
        let (overlay, _, sink) = mount(editing: existing)

        XCTAssertEqual(
            field(in: overlay, placeholder: "~/notes").text, "~/notes",
            "prefill must re-abbreviate a home-relative dir, not show the raw absolute path")

        field(in: overlay, placeholder: "npm run dev").setText("lazygit --config foo")
        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.dir?.path, homeRelativePath)
    }
}
