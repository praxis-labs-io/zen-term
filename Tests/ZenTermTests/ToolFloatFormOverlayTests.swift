import AppKit
import XCTest

@testable import ZenTerm

final class ToolFloatFormOverlayTests: WindowTestCase {
    private final class FakeCapturer: KeybindCapturing {
        private(set) var handler: ((NSEvent) -> Void)?
        var isArmed: Bool { handler != nil }
        func beginCapture(_ handler: @escaping (NSEvent) -> Void) { self.handler = handler }
        func endCapture() { handler = nil }
        func feed(_ event: NSEvent) { handler?(event) }
    }

    private final class Sink {
        var submitted: [ToolFloat] = []
        var cancelled = 0
        var deleted = 0
    }

    private var window: NSWindow?
    private var originalConfig = GeneralConfig.current

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        window = nil
        super.tearDown()
    }

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

    private func existingFloat(
        title: String, command: String = "vim", icon: String = ToolFloatParser.defaultIcon,
        dir: URL? = nil, height: CGFloat = 0.85, git: Bool = false, order: Int = 1,
        persist: ToolFloat.Persistence = .ephemeral,
        toggle: Chord = Chord(command: true, shift: true, key: "l")
    ) -> ToolFloat {
        ToolFloat(
            id: ToolFloatParser.slug(forTitle: title), order: order, title: title, icon: icon,
            command: command, dir: dir, widthFraction: 0.85, heightFraction: height,
            requiresGitRepo: git, persist: persist, toggle: toggle)
    }

    @discardableResult
    private func pressEscape() -> Bool {
        window!.contentView!.performKeyEquivalent(with: keyDown("\u{1b}", code: 53))
    }

    private func picker(in overlay: NSView) -> IconPickerField {
        descendants(of: overlay).compactMap { $0 as? IconPickerField }.first!
    }

    private func segment(in overlay: NSView, firstOption: String) -> SegmentedControl {
        descendants(of: overlay).compactMap { $0 as? SegmentedControl }
            .first { $0.optionTitles.first == firstOption }!
    }

    private func chip(in overlay: NSView) -> KeybindChip {
        descendants(of: overlay).compactMap { $0 as? KeybindChip }.first!
    }

    private func button(in overlay: NSView, title: String) -> AppButton? {
        descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    private func capture(_ chord: Chord, in overlay: NSView, _ capturer: FakeCapturer) {
        chip(in: overlay).onActivate?()
        XCTAssertTrue(capturer.isArmed, "activating the chip should arm capture")
        capturer.feed(event(for: chord))
    }

    private func submit(in overlay: NSView) {
        field(in: overlay, placeholder: "npm run dev").onSubmit?()
    }

    func test_cardFillsAvailableWidth() {
        let (overlay, _, _) = mount()
        overlay.frame = overlay.superview!.bounds
        overlay.layoutSubtreeIfNeeded()
        let titleField = field(in: overlay, placeholder: "Open GitDash")
        XCTAssertGreaterThan(titleField.frame.width, 300, "form fields should fill the card, not collapse")
    }

    func test_fillAndSubmit_buildsFloatFromControls() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("npm run dev")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.count, 1)
        let float = sink.submitted.first
        XCTAssertEqual(float?.title, "dev")
        XCTAssertEqual(float?.id, "dev", "the id is the title's slug — the user never types one")
        XCTAssertEqual(float?.command, "npm run dev")
        XCTAssertEqual(float?.toggle, novelChord)
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
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "no shortcut → submit is blocked")
    }

    func test_emptyCommand_blocksSubmit() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "empty command → submit is blocked")
    }

    func test_titleWithQuote_blocksSubmit() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        field(in: overlay, placeholder: "Open GitDash").setText("Say \" hi")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a title with a \" is rejected, so submit is blocked")
    }

    func test_conflictingShortcut_isRejected() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-floatconflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        defer {
            ConfigLoader.defaultRootOverrideForTesting = nil
            AppConfig.reload()
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try "float = title:existing command:htop key:cmd+shift+g\n"
            .write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("new")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(Chord(command: true, shift: true, key: "g"), in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a shortcut already in use is rejected, so submit is blocked")
    }

    func test_duplicateTitle_blocksSubmit() {
        let (overlay, capturer, sink) = mount(existingIDs: ["dev"])
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a title already in use → submit is blocked")
    }

    func test_titleCollidingOnlyAfterSlugging_blocksSubmit() {
        let (overlay, capturer, sink) = mount(existingIDs: ["dev-server"])
        field(in: overlay, placeholder: "Open GitDash").setText("Dev Server")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a title that slugs onto an existing id is blocked")
    }

    func test_emptyTitle_blocksSubmit() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "no title → no id to key the float by → submit is blocked")
    }

    func test_titleWithNoLettersOrNumbers_blocksSubmit() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("🎉")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a title with nothing to slug → submit is blocked")
    }

    func test_newFloat_getsNextOrder() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-form-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        defer {
            ConfigLoader.defaultRootOverrideForTesting = nil
            AppConfig.reload()
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try "float = order:4 title:existing command:htop key:cmd+shift+h\n"
            .write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("new")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.order, 5, "a new float goes after the highest existing order")
    }

    func test_iconPicker_pickFromGrid_appliesToBuiltFloat() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        let picker = picker(in: overlay)
        XCTAssertEqual(picker.selected, IconCatalog.defaultSymbol)
        picker.openForTesting()
        XCTAssertTrue(picker.isPopoverOpen)
        picker.moveHighlightForTesting(1)
        picker.commitHighlightForTesting()
        XCTAssertFalse(picker.isPopoverOpen, "committing closes the grid")
        XCTAssertEqual(picker.selected, IconCatalog.all[1])

        submit(in: overlay)
        XCTAssertEqual(sink.submitted.first?.icon, IconCatalog.all[1])
    }

    func test_footer_tabWalksSubmitCancelDelete() {
        let existing = existingFloat(title: "dev", icon: IconCatalog.defaultSymbol)
        let (overlay, _, _) = mount(editing: existing, withDelete: true)
        let buttons = descendants(of: overlay).compactMap { $0 as? AppButton }
        guard let submit = buttons.first(where: { $0.title == "Save" }),
            let cancel = buttons.first(where: { $0.title == "Cancel" }),
            let delete = buttons.first(where: { $0.title == "Delete" })
        else { return XCTFail("editing form must show Save, Cancel, and Delete") }

        window!.makeFirstResponder(submit)
        submit.keyDown(with: keyDown("\t", code: 48))
        XCTAssertTrue(KeyboardFocus.isFocused(cancel, in: window), "Tab from Save reaches Cancel")

        cancel.keyDown(with: keyDown("\t", code: 48))
        XCTAssertTrue(KeyboardFocus.isFocused(delete, in: window), "Tab from Cancel reaches Delete")
    }

    func test_iconGrid_escKeyDown_closesGrid() {
        let (overlay, _, sink) = mount()
        let picker = picker(in: overlay)
        window!.makeFirstResponder(picker)
        picker.openForTesting()
        XCTAssertTrue(picker.isPopoverOpen)

        picker.keyDown(with: keyDown("\u{1b}", code: 53))

        XCTAssertFalse(picker.isPopoverOpen, "Esc in the picker's keyDown closes the grid")
        XCTAssertEqual(sink.cancelled, 0, "closing the grid must not cancel the form")
    }

    func test_editForm_deleteButton_firesOnDelete() {
        let existing = existingFloat(title: "dev", icon: IconCatalog.defaultSymbol)
        let (overlay, _, sink) = mount(editing: existing, withDelete: true)
        let delete = descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Delete" }
        XCTAssertNotNil(delete, "editing an existing float shows a Delete button")

        delete?.onTap()

        XCTAssertEqual(sink.deleted, 1)
    }

    func test_addForm_hasNoDeleteButton() {
        let (overlay, _, _) = mount()
        let delete = descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Delete" }
        XCTAssertNil(delete, "adding a new float has no Delete button")
    }

    func test_edit_prefillsAndSavesChangedCommand() {
        let existing = existingFloat(title: "dev")
        let (overlay, _, sink) = mount(editing: existing)

        XCTAssertEqual(field(in: overlay, placeholder: "Open GitDash").text, "dev")
        XCTAssertEqual(field(in: overlay, placeholder: "npm run dev").text, "vim")

        field(in: overlay, placeholder: "npm run dev").setText("nvim")
        submit(in: overlay)

        XCTAssertEqual(sink.submitted.count, 1)
        XCTAssertEqual(sink.submitted.first?.id, "dev")
        XCTAssertEqual(sink.submitted.first?.command, "nvim")
        XCTAssertEqual(sink.submitted.first?.toggle, Chord(command: true, shift: true, key: "l"))
    }

    func test_edit_aMenuOwnedKey_prefillsUnset_andBlocksSubmit() {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let main = NSMenu()
        let top = NSMenuItem()
        let sub = NSMenu()
        let quit = NSMenuItem(title: "Quit ZenTerm", action: nil, keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        sub.addItem(quit)
        top.submenu = sub
        main.addItem(top)
        NSApp.mainMenu = main

        let existing = existingFloat(title: "dev", toggle: Chord(command: true, key: "q"))
        let (overlay, _, sink) = mount(editing: existing)

        XCTAssertNil(
            chip(in: overlay).renderedShortcutForTesting,
            "a refused key reads as unset, not as the chord the menu owns")

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "no shortcut → Save blocks until a live chord is set")
    }

    func test_edit_aDisplacedKey_prefillsUnset_andBlocksSubmit() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-floatdisplaced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        defer {
            ConfigLoader.defaultRootOverrideForTesting = nil
            AppConfig.reload()
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try "keybind = new_tab=cmd+shift+l\n".write(
            to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()

        let existing = existingFloat(title: "dev")
        let (overlay, _, sink) = mount(editing: existing)

        XCTAssertNil(
            chip(in: overlay).renderedShortcutForTesting,
            "a chord another bind holds reads as unset, the same as a menu-owned one")

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "no shortcut → Save blocks until a live chord is set")
    }

    func test_edit_changedTitle_reSlugsID_andKeepsOrder() {
        let existing = existingFloat(title: "dev", order: 3)
        let (overlay, _, sink) = mount(editing: existing)

        field(in: overlay, placeholder: "Open GitDash").setText("Dev Server")
        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.title, "Dev Server")
        XCTAssertEqual(sink.submitted.first?.id, "dev-server")
        XCTAssertEqual(sink.submitted.first?.order, 3, "a rename must not move the float in the dock")
    }

    func test_persistSegment_defaultsToEphemeral_andBuildsTheChosenMode() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("lg")
        field(in: overlay, placeholder: "npm run dev").setText("lazygit")
        capture(novelChord, in: overlay, capturer)

        segment(in: overlay, firstOption: "Fresh each time").select(1)
        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.persist, .directory)
    }

    func test_toolbarSegment_hiddenSelection_buildsHiddenFloat() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        segment(in: overlay, firstOption: "Shown").select(1)
        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.showsInToolbar, false)
    }

    func test_toolbarSegment_untouched_buildsShown() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.showsInToolbar, true)
    }

    func test_edit_prefillsHiddenToolbarSegment_andKeepsItOnSave() {
        var existing = existingFloat(title: "dev")
        existing.showsInToolbar = false
        let (overlay, _, sink) = mount(editing: existing)
        XCTAssertEqual(segment(in: overlay, firstOption: "Shown").selectedIndex, 1)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.showsInToolbar, false)
    }

    func test_persistSegment_untouched_buildsEphemeral() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("y")
        field(in: overlay, placeholder: "npm run dev").setText("yazi")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.persist, .ephemeral)
    }

    private func makeHomeRelativeDir() throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("zenterm-form-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func test_dirChooseButton_isArrowReachable() throws {
        let (overlay, _, _) = mount()
        let win = try XCTUnwrap(window)
        win.makeKeyAndOrderFront(nil)
        let dir = field(in: overlay, placeholder: "Type a path, or Choose")
        let choose = try XCTUnwrap(button(in: overlay, title: "Choose"))
        win.makeFirstResponder(dir.field)

        dir.onArrowRight?()
        XCTAssertTrue(KeyboardFocus.isFocused(choose, in: win), "Right must reach the Choose button")

        choose.onArrowLeft?()
        XCTAssertTrue(KeyboardFocus.isFocused(dir.field, in: win), "Left must return to the field")
    }

    func test_dirField_buildsPinnedDirectory() throws {
        let home = try makeHomeRelativeDir()
        let tilde = PathDisplay.abbreviatingHome(home.path)
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("notes")
        field(in: overlay, placeholder: "npm run dev").setText("nvim")
        field(in: overlay, placeholder: "Type a path, or Choose").setText(tilde)
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.dir?.path, home.standardizedFileURL.path)
    }

    func test_blankDirField_buildsNilDirectory() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("y")
        field(in: overlay, placeholder: "npm run dev").setText("yazi")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertNil(sink.submitted.first?.dir)
    }

    func test_dirWithQuote_blocksSubmit() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        field(in: overlay, placeholder: "Type a path, or Choose").setText("/tmp/a\"b")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a dir with a \" is rejected, so submit is blocked")
    }

    func test_dirField_nonexistentFolder_blocksSubmit() {
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        field(in: overlay, placeholder: "Type a path, or Choose")
            .setText("/definitely/not/a/real/path-\(UUID().uuidString)")
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertTrue(
            sink.submitted.isEmpty,
            "a nonexistent DIRECTORY blocks submit, mirroring AddWorkspaceOverlay's folder check")
    }

    func test_dirField_existingFolder_allowsSubmit() {
        let realDir = FileManager.default.temporaryDirectory
        let (overlay, capturer, sink) = mount()
        field(in: overlay, placeholder: "Open GitDash").setText("dev")
        field(in: overlay, placeholder: "npm run dev").setText("vim")
        field(in: overlay, placeholder: "Type a path, or Choose").setText(realDir.path)
        capture(novelChord, in: overlay, capturer)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.count, 1, "an existing folder must not block submit")
    }

    func test_edit_prefillsPersistAndDir() {
        let realDir = FileManager.default.temporaryDirectory
        let existing = existingFloat(
            title: "Open Lazygit", command: "lazygit", icon: "git", dir: realDir, height: 0.78,
            git: true, persist: .directory)
        let (overlay, _, sink) = mount(editing: existing)

        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.persist, .directory)
        XCTAssertEqual(sink.submitted.first?.dir?.path, realDir.path)
    }

    func test_edit_untouchedHomeRelativeDir_prefillsAbbreviatedAndRoundTripsOnSubmit() throws {
        let home = try makeHomeRelativeDir()
        let tilde = PathDisplay.abbreviatingHome(home.path)
        let existing = existingFloat(
            title: "Open Lazygit", command: "lazygit", icon: "git", dir: home, height: 0.78,
            git: true, persist: .directory)
        let (overlay, _, sink) = mount(editing: existing)

        XCTAssertEqual(
            field(in: overlay, placeholder: "Type a path, or Choose").text, tilde,
            "prefill must re-abbreviate a home-relative dir, not show the raw absolute path")

        field(in: overlay, placeholder: "npm run dev").setText("lazygit --config foo")
        submit(in: overlay)

        XCTAssertEqual(sink.submitted.first?.dir?.path, home.standardizedFileURL.path)
    }

    func test_escape_fromFocusedTextField_cancelsTheForm() {
        let (overlay, _, sink) = mount()
        window!.makeFirstResponder(field(in: overlay, placeholder: "Open GitDash").field)

        pressEscape()

        XCTAssertEqual(sink.cancelled, 1)
    }

    func test_tab_walksTheWidthHeightPair_ratherThanSkippingHeight() {
        let (overlay, _, _) = mount()
        let width = field(in: overlay, placeholder: "0.85")
        let height = descendants(of: overlay).compactMap { $0 as? FieldBox }
            .filter { $0.placeholder == "0.85" }[1]
        window!.makeFirstResponder(width.field)

        width.onTab?()
        XCTAssertTrue(
            KeyboardFocus.isFocused(height.field, in: window), "Tab from Width must reach Height")

        height.onBacktab?()
        XCTAssertTrue(KeyboardFocus.isFocused(width.field, in: window), "Shift-Tab returns to Width")
    }

    func test_escape_whileDismissing_isNotClaimed_soItReachesWhatReplacedTheCard() {
        let (overlay, _, sink) = mount()
        overlay.animateOut {}

        XCTAssertFalse(pressEscape(), "a dismissing card must let Esc pass to the card behind it")

        XCTAssertEqual(sink.cancelled, 0, "and must not re-run its own cancel")
    }
}
