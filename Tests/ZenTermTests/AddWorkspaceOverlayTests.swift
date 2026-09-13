import AppKit
import XCTest

@testable import ZenTerm

final class AddWorkspaceOverlayTests: WindowTestCase {
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

    func test_editingAWorkspace_roundTripsCarryThroughThePicker() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            main: nil, right: nil, bottom: nil, focus: .main, env: [:],
            carry: ["node_modules", ".env"])
        let (overlay, sink) = mount(editing: ws)
        field(in: overlay, placeholder: "Workspace name").setText("Renamed")

        try XCTUnwrap(button(in: overlay, title: "Save")).onTap()

        XCTAssertEqual(sink.submitted.first?.title, "Renamed")
        XCTAssertEqual(sink.submitted.first?.carry, ["node_modules", ".env"])
    }

    func test_choosingAFolder_loadsWhatGitIgnoresThere() throws {
        let dir = try makeRealDir()
        let (overlay, _) = mount()
        let carry = try XCTUnwrap(carryPicker(in: overlay))
        carry.settle = 0
        carry.probe = { _, _ in
            IgnoredCatalog(
                entries: ["node_modules", ".env"], resting: ["node_modules", ".env"], fileCounts: [:], directories: [])
        }
        let landed = expectation(description: "catalog")
        carry.onChanged = { if !carry.catalog.isEmpty { landed.fulfill() } }

        picker(in: overlay).setText(dir.path)
        picker(in: overlay).field.onChange?()
        wait(for: [landed], timeout: 2)

        XCTAssertEqual(carry.catalog, ["node_modules", ".env"])
    }

    func test_whatIsPickedInCarry_isWhatIsSubmitted() throws {
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "ZenTerm", path: dir, main: nil, right: nil, bottom: nil, focus: .main,
            env: [:], carry: [".env"])
        let (overlay, sink) = mount(editing: ws)
        let carry = try XCTUnwrap(carryPicker(in: overlay))

        carry.setCarried([".env", "node_modules"])
        try XCTUnwrap(button(in: overlay, title: "Save")).onTap()

        XCTAssertEqual(sink.submitted.first?.carry, [".env", "node_modules"])
    }

    func test_carryIsAVerticalStopOnlyOnceItHasAList() throws {
        let dir = try makeRealDir()
        let (overlay, _) = mount()
        let carry = try XCTUnwrap(carryPicker(in: overlay))
        XCTAssertNil(carry.focusStop)

        loadCarry(carry, in: overlay, folder: dir, ignoring: ["node_modules"])

        XCTAssertNotNil(carry.focusStop)
    }

    func test_downFromTheEnvButton_reachesTheCarryList() throws {
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "ZenTerm", path: dir, main: nil, right: nil, bottom: nil, focus: .main,
            env: [:], carry: ["node_modules"])
        let (overlay, _) = mount(editing: ws)
        let carry = try XCTUnwrap(carryPicker(in: overlay))
        loadCarry(carry, in: overlay, folder: dir, ignoring: ["node_modules"])
        let list = try XCTUnwrap(carry.focusStop)
        let addVar = try XCTUnwrap(button(in: overlay, title: "＋ Add variable"))
        window?.makeFirstResponder(addVar)

        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        addVar.keyDown(
            with: try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                    timestamp: 0, windowNumber: 0, context: nil, characters: down,
                    charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125)))

        XCTAssertTrue(KeyboardFocus.isFocused(list, in: window), "Down off ＋ Add variable lands on CARRY")
    }

    func test_theCard_staysUnderTheSettingsHeight_howeverMuchItHolds() throws {
        let ws = Workspace(
            title: "Big", path: try makeRealDir(), main: "nvim", right: "claude", bottom: "shell",
            focus: .bottom, env: Dictionary(uniqueKeysWithValues: (0..<12).map { ("KEY\($0)", "v") }),
            carry: (0..<20).map { "entry-\($0)" })
        let overlay = AddWorkspaceOverlay(
            editing: ws, existingTitles: [], background: Theme.current.chrome.background.nsColor,
            onSubmit: { _ in }, onCancel: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        window = win
        win.contentView?.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? CardView }.first)
        XCTAssertLessThanOrEqual(card.frame.height, FormCard.maxHeight)
        XCTAssertGreaterThan(card.frame.height, 0)
    }

    private func loadCarry(
        _ carry: CarryPicker, in overlay: AddWorkspaceOverlay, folder: URL, ignoring: [String]
    ) {
        carry.settle = 0
        carry.probe = { _, _ in IgnoredCatalog(entries: ignoring, resting: ignoring, fileCounts: [:], directories: []) }
        let landed = expectation(description: "catalog")
        carry.onChanged = { if carry.focusStop != nil { landed.fulfill() } }
        picker(in: overlay).setText(folder.path)
        picker(in: overlay).field.onChange?()
        wait(for: [landed], timeout: 2)
        carry.onChanged = nil
    }

    private func carryPicker(in overlay: NSView) -> CarryPicker? {
        descendants(of: overlay).compactMap { $0 as? CarryPicker }.first
    }

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

    private func segment(in overlay: NSView, containing title: String) -> SegmentedControl? {
        descendants(of: overlay).compactMap { $0 as? SegmentedControl }.first { control in
            descendants(of: control).compactMap { $0 as? AppButton }.contains { $0.title == title }
        }
    }

    @discardableResult
    private func pressEscape() -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window!.contentView!.performKeyEquivalent(with: esc)
    }

    private func setPresetConfig(editor: String, ai: String) {
        let original = GeneralConfig.current
        var overridden = original
        overridden.editor = editor
        overridden.ai = ai
        GeneralConfig.setCurrentForTesting(overridden)
        addTeardownBlock { GeneralConfig.setCurrentForTesting(original) }
    }

    private func makeRealDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

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
        let (overlay, _) = mount()
        XCTAssertNil(button(in: overlay, title: "Delete"), "adding a new workspace has no Delete button")
    }

    func test_addForm_editorAIShellPreset_usesConfiguredEditorAndAI() throws {
        setPresetConfig(editor: "vim", ai: "codex")
        let dir = try makeRealDir()
        let (overlay, sink) = mount()

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

    func test_editForm_builtInDefaultRecipe_selectsPresetUnderChangedConfig() throws {
        setPresetConfig(editor: "vim", ai: "codex")
        let dir = try makeRealDir()
        let ws = Workspace(
            title: "Delta", path: dir, main: "nvim", right: "claude", bottom: "shell",
            focus: .main, env: [:])
        let (overlay, _) = mount(editing: ws)

        XCTAssertEqual(segment(in: overlay, containing: "Editor + AI + Shell")?.selectedIndex, 1)
    }

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

    private func picker(in overlay: NSView) -> DirectoryPickerField {
        descendants(of: overlay).compactMap { $0 as? DirectoryPickerField }.first!
    }

    func test_folderChooseButton_opensThePicker() throws {
        let (overlay, _) = mount()
        var opened = false
        picker(in: overlay).presentPanel = { _, _, _ in opened = true }

        try XCTUnwrap(button(in: overlay, title: "Choose")).onTap()

        XCTAssertTrue(opened, "the Choose button must open the folder picker")
    }

    func test_folderPick_seedsTitleFromFolderName() throws {
        let (overlay, _) = mount()
        picker(in: overlay).presentPanel = { _, _, completion in
            completion(URL(fileURLWithPath: "/tmp/my-project", isDirectory: true))
        }

        try XCTUnwrap(button(in: overlay, title: "Choose")).onTap()

        XCTAssertEqual(field(in: overlay, placeholder: "Workspace name").text, "my-project")
    }

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

    func test_escape_fromFocusedTextField_cancelsTheForm() {
        let (overlay, sink) = mount()
        window!.makeFirstResponder(field(in: overlay, placeholder: "Workspace name").field)

        XCTAssertTrue(pressEscape(), "the card root must claim Esc")

        XCTAssertEqual(sink.cancelled, 1)
    }

    func test_escape_fromFocusedSegmentedControl_cancelsTheForm() throws {
        let (overlay, sink) = mount()
        let layout = try XCTUnwrap(segment(in: overlay, containing: "Editor + AI + Shell"))
        window!.makeFirstResponder(layout)

        pressEscape()

        XCTAssertEqual(sink.cancelled, 1)
    }
}
