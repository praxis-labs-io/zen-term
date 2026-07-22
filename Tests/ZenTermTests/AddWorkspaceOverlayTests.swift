import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the workspace add / edit form's ZEN-112 additions — edit-mode prefill and
/// the Delete button — driven through the real controls in a window. A state-only test would pass
/// while the control was dead, the failure mode the project's interaction-test rule guards against.
final class AddWorkspaceOverlayTests: XCTestCase {
    private final class Sink {
        var submitted: [Workspace] = []
        var cancelled = 0
        var deleted = 0
    }

    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    // MARK: harness

    private func mount(
        editing: Workspace? = nil, existingTitles: Set<String> = [], withDelete: Bool = false
    ) -> (overlay: AddWorkspaceOverlay, sink: Sink) {
        let sink = Sink()
        let overlay = AddWorkspaceOverlay(
            editing: editing, existingTitles: existingTitles,
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
        return (overlay, sink)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func field(in overlay: NSView, placeholder: String) -> FieldBox {
        descendants(of: overlay).compactMap { $0 as? FieldBox }.first { $0.placeholder == placeholder }!
    }

    private func button(in overlay: NSView, title: String) -> AppButton? {
        descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    /// The segmented control whose segments include `title` — distinguishes the layout picker
    /// ("Editor + AI + Shell") from the focus picker, which both have three segments.
    private func segment(in overlay: NSView, containing title: String) -> SegmentedControl? {
        descendants(of: overlay).compactMap { $0 as? SegmentedControl }.first { control in
            descendants(of: control).compactMap { $0 as? AppButton }.contains { $0.title == title }
        }
    }

    /// Press Esc the way `NSWindow.sendEvent` does — a `performKeyEquivalent` traversal of the
    /// contentView subtree, which is where the card root claims it (ZEN-149). Driving the root
    /// directly would skip the Cancel button's key equivalent, which is the point of the traversal.
    @discardableResult
    private func pressEscape() -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window!.contentView!.performKeyEquivalent(with: esc)
    }

    /// Override the configured preset editor / AI for one test, restoring `current` on teardown.
    private func setPresetConfig(editor: String, ai: String) {
        let original = GeneralConfig.current
        var overridden = original
        overridden.editor = editor
        overridden.ai = ai
        GeneralConfig.setCurrentForTesting(overridden)
        addTeardownBlock { GeneralConfig.setCurrentForTesting(original) }
    }

    /// A real on-disk directory, so the form's "that folder exists" validation passes on submit.
    private func makeRealDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: tests

    func test_editForm_prefillsTitleAndFolder() throws {
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "Alpha", path: dir, main: "nvim", right: "claude", bottom: "shell",
            focus: .main, env: [:])
        let (overlay, _) = mount(editing: ws)

        XCTAssertEqual(field(in: overlay, placeholder: "Workspace name").text, "Alpha")
        XCTAssertEqual(
            field(in: overlay, placeholder: "Type a path, or Choose").text,
            PathDisplay.abbreviatingHome(dir.path))
    }

    func test_editForm_savesChangedTitle() throws {
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "Alpha", path: dir, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
        let (overlay, sink) = mount(editing: ws)

        field(in: overlay, placeholder: "Workspace name").setText("Renamed")
        button(in: overlay, title: "Save")?.onTap()

        XCTAssertEqual(sink.submitted.count, 1)
        XCTAssertEqual(sink.submitted.first?.title, "Renamed")
        XCTAssertEqual(sink.submitted.first?.path, dir)
    }

    func test_editForm_hasSaveButton_notAdd() throws {
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "Alpha", path: dir, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
        let (overlay, _) = mount(editing: ws)
        XCTAssertNotNil(button(in: overlay, title: "Save"))
        XCTAssertNil(button(in: overlay, title: "Add Workspace"))
    }

    func test_editForm_deleteButton_firesOnDelete() throws {
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "Alpha", path: dir, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
        let (overlay, sink) = mount(editing: ws, withDelete: true)
        let delete = button(in: overlay, title: "Delete")
        XCTAssertNotNil(delete, "editing an existing workspace shows a Delete button")

        delete?.onTap()

        XCTAssertEqual(sink.deleted, 1)
    }

    func test_addForm_hasNoDeleteButton() {
        let (overlay, _) = mount()  // add mode
        XCTAssertNil(button(in: overlay, title: "Delete"), "adding a new workspace has no Delete button")
    }

    func test_addForm_editorAIShellPreset_usesConfiguredEditorAndAI() throws {
        setPresetConfig(editor: "vim", ai: "codex")
        let dir = try makeRealDir()
        let (overlay, sink) = mount()  // add mode defaults to the "Editor + AI + Shell" segment

        field(in: overlay, placeholder: "Workspace name").setText("Beta")
        field(in: overlay, placeholder: "Type a path, or Choose")
            .setText(PathDisplay.abbreviatingHome(dir.path))
        button(in: overlay, title: "Add Workspace")?.onTap()

        XCTAssertEqual(sink.submitted.count, 1)
        XCTAssertEqual(sink.submitted.first?.main, "vim")
        XCTAssertEqual(sink.submitted.first?.right, "codex")
        XCTAssertEqual(sink.submitted.first?.bottom, "shell")
    }

    func test_editForm_matchingConfiguredPreset_selectsEditorAIShellSegment() throws {
        setPresetConfig(editor: "vim", ai: "codex")
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "Gamma", path: dir, main: "vim", right: "codex", bottom: "shell",
            focus: .main, env: [:])
        let (overlay, _) = mount(editing: ws)

        XCTAssertEqual(segment(in: overlay, containing: "Editor + AI + Shell")?.selectedIndex, 1)
    }

    /// A workspace stamped with the built-in default (nvim/claude) still reads as the preset after
    /// the user reconfigures editor/AI — it doesn't silently drop to Custom.
    func test_editForm_builtInDefaultRecipe_selectsPresetUnderChangedConfig() throws {
        setPresetConfig(editor: "vim", ai: "codex")  // config now differs from the stored recipe
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "Delta", path: dir, main: "nvim", right: "claude", bottom: "shell",
            focus: .main, env: [:])
        let (overlay, _) = mount(editing: ws)

        XCTAssertEqual(segment(in: overlay, containing: "Editor + AI + Shell")?.selectedIndex, 1)
    }

    // MARK: Tab (ZEN-146)

    /// An env row is ONE vertical stop (its KEY box), so routing the value box's Tab through
    /// `moveVertical` jumped from KEY straight to the next row — silently skipping the value the
    /// user was about to type. Tab walks the row in reading order instead.
    func test_tab_walksAnEnvRow_ratherThanSkippingItsValueBox() throws {
        let (overlay, _) = mount()
        let addVar = try XCTUnwrap(button(in: overlay, title: "＋ Add variable"))
        addVar.onTap()
        let rows = descendants(of: overlay).compactMap { $0 as? EnvRow }
        let row = try XCTUnwrap(rows.first)
        window!.makeFirstResponder(row.keyBox.field)

        row.keyBox.onTab?()
        XCTAssertTrue(
            KeyboardFocus.isFocused(row.valueBox.field, in: window),
            "Tab from an env KEY must reach its own value box, not the next row")

        row.valueBox.onBacktab?()
        XCTAssertTrue(KeyboardFocus.isFocused(row.keyBox.field, in: window), "Shift-Tab returns to KEY")
    }

    // MARK: folder picker

    private func picker(in overlay: NSView) -> DirectoryPickerField {
        descendants(of: overlay).compactMap { $0 as? DirectoryPickerField }.first!
    }

    /// The folder field carries a Choose button that opens the picker whether the field is empty or
    /// already holds a path — the affordance is the button, not a click on the input. Presentation
    /// goes through the picker's seam, so no real panel is popped.
    func test_folderChooseButton_opensThePicker() throws {
        let (overlay, _) = mount()
        var opened = false
        picker(in: overlay).presentPanel = { _, _, _ in opened = true }

        try XCTUnwrap(button(in: overlay, title: "Choose")).onTap()

        XCTAssertTrue(opened, "the Choose button must open the folder picker")
    }

    /// Choosing a folder seeds the workspace title from its last path component (until the user has
    /// edited the title themselves).
    func test_folderPick_seedsTitleFromFolderName() throws {
        let (overlay, _) = mount()
        picker(in: overlay).presentPanel = { _, _, completion in
            completion(URL(fileURLWithPath: "/tmp/my-project", isDirectory: true))
        }

        try XCTUnwrap(button(in: overlay, title: "Choose")).onTap()

        XCTAssertEqual(field(in: overlay, placeholder: "Workspace name").text, "my-project")
    }

    /// The Choose button is keyboard-reachable, not mouse-only: Right off the folder field lands on
    /// it, Left returns. Guards the dead-control failure mode the project's interaction rule exists
    /// for — a button that renders but no arrow key can reach.
    func test_folderChooseButton_isArrowReachable() throws {
        let (overlay, _) = mount()
        let win = try XCTUnwrap(window)
        win.makeKeyAndOrderFront(nil)
        let folder = field(in: overlay, placeholder: "Type a path, or Choose")
        let choose = try XCTUnwrap(button(in: overlay, title: "Choose"))
        win.makeFirstResponder(folder.field)

        folder.onArrowRight?()
        XCTAssertTrue(KeyboardFocus.isFocused(choose, in: win), "Right must reach the Choose button")

        choose.onArrowLeft?()
        XCTAssertTrue(KeyboardFocus.isFocused(folder.field, in: win), "Left must return to the field")
    }

    // MARK: Esc (ZEN-149)

    /// Esc closes the form from a focused text field — the case the Cancel button's key equivalent
    /// used to cover by accident, now owned by the card root.
    func test_escape_fromFocusedTextField_cancelsTheForm() {
        let (overlay, sink) = mount()
        window!.makeFirstResponder(field(in: overlay, placeholder: "Workspace name").field)

        XCTAssertTrue(pressEscape(), "the card root must claim Esc")

        XCTAssertEqual(sink.cancelled, 1)
    }

    /// The dead-Esc site: `wireSegment` never wired `onEsc`, so Esc on a focused segmented control
    /// only worked because the Cancel button's key equivalent caught it. The root now owns it.
    func test_escape_fromFocusedSegmentedControl_cancelsTheForm() throws {
        let (overlay, sink) = mount()
        let layout = try XCTUnwrap(segment(in: overlay, containing: "Editor + AI + Shell"))
        window!.makeFirstResponder(layout)

        pressEscape()

        XCTAssertEqual(sink.cancelled, 1)
    }
}
