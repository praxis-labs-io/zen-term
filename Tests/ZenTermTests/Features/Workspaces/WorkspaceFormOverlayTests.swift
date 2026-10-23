import AppKit
import XCTest

@testable import ZenTerm

final class WorkspaceFormOverlayTests: WindowTestCase {
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

    private func mount(
        editing: Workspace? = nil, existingTitles: Set<String> = [], withDelete: Bool = false
    ) -> (overlay: WorkspaceFormOverlay, sink: Sink) {
        let sink = Sink()
        let overlay = WorkspaceFormOverlay(
            editing: editing, existingTitles: existingTitles,
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { sink.submitted.append($0) },
            onCancel: { sink.cancelled += 1 },
            onDelete: withDelete ? { sink.deleted += 1 } : nil)
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        window = win
        win.makeKeyAndOrderFront(nil)
        win.contentView?.layoutSubtreeIfNeeded()
        return (overlay, sink)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func button(in overlay: NSView, title: String) -> AppButton? {
        descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    private func visibleText(in overlay: NSView) -> [String] {
        descendants(of: overlay).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
    }

    private func picker(in overlay: WorkspaceFormOverlay) -> DirectoryPickerField { overlay.folderFieldForTesting }

    private func carryPicker(in overlay: NSView) -> CarryPicker? {
        descendants(of: overlay).compactMap { $0 as? CarryPicker }.first
    }

    private func makeRealDir(named name: String = "zenterm-ws") throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-form-\(UUID().uuidString)", isDirectory: true)
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return dir
    }

    private func typeFolder(_ text: String, in overlay: WorkspaceFormOverlay) {
        picker(in: overlay).setText(text)
        picker(in: overlay).field.onChange?()
    }

    private func typeName(_ text: String, in overlay: WorkspaceFormOverlay) {
        overlay.titleFieldForTesting.setText(text)
        overlay.titleFieldForTesting.onChange?()
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func escapeKey() throws -> NSEvent { try key(53, "\u{1b}") }

    private func arrow(_ code: UInt16, _ scalar: Int) throws -> NSEvent {
        try key(code, String(UnicodeScalar(scalar)!), flags: [.function, .numericPad])
    }

    private var editor: NSTextView? { window?.firstResponder as? NSTextView }

    private func save(_ overlay: WorkspaceFormOverlay, editing: Bool = false) throws {
        try XCTUnwrap(button(in: overlay, title: editing ? "Save" : "Add Workspace")).onTap()
    }

    func test_theAddCard_opensWithOneShellTab_focusedOnItsMainPane() throws {
        let (overlay, _) = mount()

        XCTAssertEqual(overlay.tabStripForTesting.chips.map(\.title), ["shell"])
        XCTAssertTrue(overlay.tabStripForTesting.chips[0].isDotVisibleForTesting)
        XCTAssertTrue(try XCTUnwrap(overlay.drawingForTesting.region(.main)).isMarkerVisibleForTesting)
        XCTAssertEqual(overlay.titleFieldForTesting.placeholder, "Named after the folder")
        XCTAssertNil(button(in: overlay, title: "Delete"))
        XCTAssertNotNil(button(in: overlay, title: "Add Workspace"))
    }

    func test_theEditCard_changesOnlyItsHeaderAndButtons() throws {
        let ws = Workspace(title: "Alpha", path: try makeRealDir(), tabs: [], env: [:])
        let (overlay, sink) = mount(editing: ws, withDelete: true)

        XCTAssertTrue(visibleText(in: overlay).contains("Edit Workspace"))
        XCTAssertNotNil(button(in: overlay, title: "Save"))
        XCTAssertNil(button(in: overlay, title: "Add Workspace"))
        try XCTUnwrap(button(in: overlay, title: "Delete")).onTap()
        XCTAssertEqual(sink.deleted, 1)
    }

    func test_editingAFlatWorkspace_roundTripsUnchanged() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            tabs: [Workspace.Tab(main: "nvim", right: "claude", bottom: "shell")],
            focus: Workspace.LaunchFocus(tab: 0, region: .right),
            env: ["PORT": "3000"], carry: ["node_modules", ".env"])
        let (overlay, sink) = mount(editing: ws)

        try save(overlay, editing: true)

        XCTAssertEqual(sink.submitted, [ws])
        XCTAssertEqual(
            WorkspacesWriter.serialize(try XCTUnwrap(sink.submitted.first)), WorkspacesWriter.serialize(ws),
            "a v1.3.0 workspace writes back as the same flat section")
    }

    func test_editingAMultiTabWorkspace_keepsEveryTabAndItsFocus() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            tabs: [Workspace.Tab(name: "editor", main: "nvim"), Workspace.Tab(name: "gate", bottom: "bin/check")],
            focus: Workspace.LaunchFocus(tab: 1, region: .bottom), env: [:])
        let (overlay, sink) = mount(editing: ws)

        XCTAssertEqual(overlay.tabStripForTesting.chips.map(\.title), ["editor", "gate"])
        try save(overlay, editing: true)

        XCTAssertEqual(sink.submitted.first?.tabs, ws.tabs)
        XCTAssertEqual(sink.submitted.first?.focus, ws.focus)
    }

    func test_aFolderNameTheFileCantHold_isRejected_whenTheNameComesFromTheFolder() throws {
        let (overlay, sink) = mount()
        typeFolder(try makeRealDir(named: "app#2").path, in: overlay)
        typeName("", in: overlay)

        try save(overlay)

        XCTAssertTrue(sink.submitted.isEmpty, "a [app#2] header would not read back")
        XCTAssertTrue(KeyboardFocus.isFocused(overlay.titleFieldForTesting.field, in: window))
    }

    func test_movingATabMidRename_keepsTheNewNameOnThatTab() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            tabs: [Workspace.Tab(name: "a"), Workspace.Tab(name: "b"), Workspace.Tab(name: "c")], env: [:])
        let (overlay, sink) = mount(editing: ws)
        let strip = overlay.tabStripForTesting
        overlay.handle(.selectTab(2))
        strip.beginRenamingSelected()
        try XCTUnwrap(editor).string = "renamed"

        XCTAssertTrue(overlay.handle(.moveTabRight))
        try save(overlay, editing: true)

        XCTAssertEqual(sink.submitted.first?.tabs.map(\.name), ["a", "c", "renamed"])
    }

    func test_closingATabMidRename_leavesTheOtherTabsNamesAlone() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            tabs: [Workspace.Tab(name: "a"), Workspace.Tab(name: "b"), Workspace.Tab(name: "c")], env: [:])
        let (overlay, sink) = mount(editing: ws)
        overlay.handle(.selectTab(2))
        overlay.tabStripForTesting.beginRenamingSelected()
        try XCTUnwrap(editor).string = "renamed"

        XCTAssertTrue(overlay.handle(.closeTab))
        try save(overlay, editing: true)

        XCTAssertEqual(sink.submitted.first?.tabs.map(\.name), ["a", "c"])
    }

    func test_addingRenamingAndEditingATab_isWhatIsSaved() throws {
        let (overlay, sink) = mount()
        typeFolder(try makeRealDir(named: "site").path, in: overlay)
        let strip = overlay.tabStripForTesting

        strip.addButtonForTesting.performClick(nil)
        XCTAssertEqual(strip.chips.map(\.title), ["shell", "shell"])
        XCTAssertTrue(
            KeyboardFocus.isFocused(try XCTUnwrap(overlay.drawingForTesting.region(.main)).field, in: window),
            "a new tab opens with its main pane focused")
        try XCTUnwrap(editor).insertText("npm run dev", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(strip.chips[1].title, "npm run dev", "an unnamed chip reads its main command")

        strip.beginRenamingSelected()
        try XCTUnwrap(editor).string = "server"
        try XCTUnwrap(editor).insertNewline(nil)
        try save(overlay)

        XCTAssertEqual(
            sink.submitted.first?.tabs, [Workspace.Tab(), Workspace.Tab(name: "server", main: "npm run dev")])
    }

    func test_removingATab_needsNoConfirm_andUndoPutsItBack() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            tabs: [Workspace.Tab(main: "nvim", right: "claude"), Workspace.Tab(name: "gate", bottom: "bin/check")],
            focus: Workspace.LaunchFocus(tab: 0, region: .right), env: [:])
        let (overlay, sink) = mount(editing: ws)

        overlay.tabStripForTesting.chips[0].closeButtonForTesting.onClick()

        XCTAssertEqual(overlay.tabStripForTesting.chips.map(\.title), ["gate"])
        XCTAssertEqual(overlay.noticeForTesting, "Removed nvim. gate's main pane opens focused.")
        XCTAssertTrue(overlay.tabStripForTesting.chips[0].isDotVisibleForTesting)

        try XCTUnwrap(overlay.undoButtonForTesting).onTap()

        XCTAssertEqual(overlay.tabStripForTesting.chips.map(\.title), ["nvim", "gate"])
        XCTAssertNil(overlay.noticeForTesting)
        XCTAssertNil(overlay.undoButtonForTesting)
        try save(overlay, editing: true)
        XCTAssertEqual(sink.submitted.first?.tabs, ws.tabs)
        XCTAssertEqual(sink.submitted.first?.focus, ws.focus)
    }

    func test_theNextTabChange_takesTheUndoAway() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            tabs: [Workspace.Tab(main: "a"), Workspace.Tab(main: "b"), Workspace.Tab(main: "c")], env: [:])
        let (overlay, _) = mount(editing: ws)

        XCTAssertTrue(overlay.handle(.closeTab))
        XCTAssertNotNil(overlay.undoButtonForTesting)

        XCTAssertTrue(overlay.handle(.moveTabRight))
        XCTAssertNil(overlay.undoButtonForTesting)
        XCTAssertNil(overlay.noticeForTesting)
    }

    func test_tabChords_addMoveSwitchAndRemove() throws {
        let (overlay, _) = mount()
        typeFolder(try makeRealDir().path, in: overlay)

        XCTAssertTrue(overlay.handle(.newTab))
        XCTAssertTrue(overlay.handle(.newTab))
        XCTAssertEqual(overlay.formForTesting.selected, 2)

        XCTAssertTrue(overlay.handle(.moveTabLeft))
        XCTAssertEqual(overlay.formForTesting.selected, 1)

        XCTAssertTrue(overlay.handle(.selectTab(1)))
        XCTAssertEqual(overlay.formForTesting.selected, 0)
        XCTAssertTrue(overlay.handle(.prevTab))
        XCTAssertEqual(overlay.formForTesting.selected, 2, "previous wraps, as in the tab bar")

        XCTAssertTrue(overlay.handle(.closeTab))
        XCTAssertEqual(overlay.tabStripForTesting.chips.count, 2)
        XCTAssertFalse(overlay.handle(.toggleSidebar), "chords the form has no use for are left to the window")
    }

    func test_theSoleTab_cannotBeClosed() {
        let (overlay, _) = mount()

        XCTAssertTrue(overlay.handle(.closeTab))

        XCTAssertEqual(overlay.tabStripForTesting.chips.count, 1)
        XCTAssertNil(overlay.noticeForTesting)
    }

    func test_commandL_inARegion_movesTheLaunchFocusThere() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(), tabs: [Workspace.Tab(main: "nvim", right: "claude")], env: [:])
        let (overlay, sink) = mount(editing: ws)
        overlay.drawingForTesting.focus(.right)

        XCTAssertTrue(overlay.performKeyEquivalent(with: try key(37, "l", flags: [.command])))

        XCTAssertTrue(try XCTUnwrap(overlay.drawingForTesting.region(.right)).isMarkerVisibleForTesting)
        try save(overlay, editing: true)
        XCTAssertEqual(sink.submitted.first?.focus, Workspace.LaunchFocus(tab: 0, region: .right))
    }

    func test_commandL_matchesTheCharacterTyped_notWhereTheKeySitsOnQWERTY() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(), tabs: [Workspace.Tab(main: "nvim", right: "claude")], env: [:])
        let (overlay, _) = mount(editing: ws)
        overlay.drawingForTesting.focus(.right)

        XCTAssertTrue(overlay.performKeyEquivalent(with: try key(35, "l", flags: [.command])), "Dvorak's L")
        XCTAssertTrue(try XCTUnwrap(overlay.drawingForTesting.region(.right)).isMarkerVisibleForTesting)
    }

    func test_emptyingTheDrawerThatOpensFocused_movesItToTheMainPane_andTheFooterSaysSo() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            tabs: [Workspace.Tab(name: "gate", main: "nvim", bottom: "bin/check")],
            focus: Workspace.LaunchFocus(tab: 0, region: .bottom), env: [:])
        let (overlay, sink) = mount(editing: ws)
        overlay.drawingForTesting.focus(.bottom)
        let field = try XCTUnwrap(editor)

        field.selectAll(nil)
        field.deleteBackward(nil)
        field.keyDown(with: try arrow(126, NSUpArrowFunctionKey))

        XCTAssertEqual(overlay.noticeForTesting, "The bottom drawer is closed. gate's main pane opens focused.")
        XCTAssertNil(overlay.undoButtonForTesting)
        try save(overlay, editing: true)
        XCTAssertEqual(sink.submitted.first?.focus, .start)
        XCTAssertNil(sink.submitted.first?.tabs[0].bottom)
    }

    func test_typingAFolder_namesTheWorkspaceAfterIt() throws {
        let (overlay, sink) = mount()

        typeFolder(try makeRealDir(named: "zen-term").path, in: overlay)
        XCTAssertEqual(overlay.titleFieldForTesting.text, "zen-term")

        typeFolder(try makeRealDir(named: "site").path, in: overlay)
        XCTAssertEqual(overlay.titleFieldForTesting.text, "site", "a name filled for you keeps following")

        try save(overlay)
        XCTAssertEqual(sink.submitted.first?.title, "site")
    }

    func test_choosingAFolder_namesTheWorkspaceAfterIt() throws {
        let (overlay, _) = mount()
        picker(in: overlay).presentPanel = { _, _, completion in
            completion(URL(fileURLWithPath: "/tmp/my-project", isDirectory: true))
        }

        try XCTUnwrap(button(in: overlay, title: "Choose")).onTap()

        XCTAssertEqual(overlay.titleFieldForTesting.text, "my-project")
    }

    func test_aNameTypedBeforeTheFolder_isNeverReplaced() throws {
        let (overlay, sink) = mount()

        typeName("Site", in: overlay)
        typeFolder(try makeRealDir(named: "zen-term").path, in: overlay)

        XCTAssertEqual(overlay.titleFieldForTesting.text, "Site")
        try save(overlay)
        XCTAssertEqual(sink.submitted.first?.title, "Site")
    }

    func test_clearingTheName_handsItBackToTheFolder() throws {
        let (overlay, sink) = mount()
        typeFolder(try makeRealDir(named: "zen-term").path, in: overlay)
        typeName("Site", in: overlay)

        typeName("", in: overlay)
        XCTAssertEqual(overlay.titleFieldForTesting.placeholder, "zen-term")
        try save(overlay)
        XCTAssertEqual(sink.submitted.first?.title, "zen-term", "Save uses the name it shows")

        typeFolder(try makeRealDir(named: "site").path, in: overlay)
        XCTAssertEqual(overlay.titleFieldForTesting.text, "site", "and it follows the folder again")
    }

    func test_editing_theNameStaysPut_untilItIsCleared() throws {
        let ws = Workspace(title: "Alpha", path: try makeRealDir(named: "alpha"), tabs: [], env: [:])
        let (overlay, _) = mount(editing: ws)

        typeFolder(try makeRealDir(named: "beta").path, in: overlay)
        XCTAssertEqual(overlay.titleFieldForTesting.text, "Alpha")

        typeName("", in: overlay)
        typeFolder(try makeRealDir(named: "gamma").path, in: overlay)
        XCTAssertEqual(overlay.titleFieldForTesting.text, "gamma")
    }

    func test_save_showsEveryProblemAtOnce_andFocusesTheFirst() throws {
        let (overlay, sink) = mount(existingTitles: ["Site"])
        typeName("Site", in: overlay)
        typeFolder("/no/such/folder-\(UUID().uuidString)", in: overlay)

        try save(overlay)

        XCTAssertTrue(sink.submitted.isEmpty)
        let text = visibleText(in: overlay)
        XCTAssertTrue(text.contains("A workspace named Site already exists."))
        XCTAssertTrue(text.contains("That folder doesn't exist."))
        XCTAssertTrue(KeyboardFocus.isFocused(overlay.titleFieldForTesting.field, in: window))
    }

    func test_aTabNameWithAQuote_isRefused_andItsChipFocused() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(), tabs: [Workspace.Tab(main: "a"), Workspace.Tab(main: "b")],
            env: [:])
        let (overlay, sink) = mount(editing: ws)
        overlay.tabStripForTesting.onRename?(1, "say \"hi\"")

        try save(overlay, editing: true)

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertTrue(visibleText(in: overlay).contains("Tab names can't contain a \" character."))
        XCTAssertEqual(overlay.formForTesting.selected, 1)
        XCTAssertIdentical(window?.firstResponder, overlay.tabStripForTesting.chips[1])
    }

    func test_aCommandWithAQuote_inAnotherTab_selectsThatTabAndFocusesTheRegion() throws {
        let ws = Workspace(
            title: "ZenTerm", path: try makeRealDir(),
            tabs: [Workspace.Tab(main: "a"), Workspace.Tab(main: "b", right: "echo \"x\"")], env: [:])
        let (overlay, sink) = mount(editing: ws)

        try save(overlay, editing: true)

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(overlay.formForTesting.selected, 1)
        XCTAssertTrue(
            KeyboardFocus.isFocused(try XCTUnwrap(overlay.drawingForTesting.region(.right)).field, in: window))
    }

    func test_addVariable_addsARow_andFocusesItsKey() throws {
        let (overlay, _) = mount()

        try XCTUnwrap(button(in: overlay, title: "＋ Add variable")).onTap()

        let row = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? EnvRow }.first)
        XCTAssertTrue(KeyboardFocus.isFocused(row.keyBox.field, in: window))
    }

    func test_tab_walksAnEnvRow_ratherThanSkippingItsValueBox() throws {
        let (overlay, _) = mount()
        try XCTUnwrap(button(in: overlay, title: "＋ Add variable")).onTap()
        let row = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? EnvRow }.first)
        window!.makeFirstResponder(row.keyBox.field)

        row.keyBox.onTab?()
        XCTAssertTrue(KeyboardFocus.isFocused(row.valueBox.field, in: window))

        row.valueBox.onBacktab?()
        XCTAssertTrue(KeyboardFocus.isFocused(row.keyBox.field, in: window))
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

        typeFolder(dir.path, in: overlay)
        wait(for: [landed], timeout: 2)

        XCTAssertEqual(carry.catalog, ["node_modules", ".env"])
    }

    func test_whatIsPickedInCarry_isWhatIsSubmitted() throws {
        let ws = Workspace(title: "ZenTerm", path: try makeRealDir(), tabs: [], env: [:], carry: [".env"])
        let (overlay, sink) = mount(editing: ws)

        try XCTUnwrap(carryPicker(in: overlay)).setCarried([".env", "node_modules"])
        try save(overlay, editing: true)

        XCTAssertEqual(sink.submitted.first?.carry, [".env", "node_modules"])
    }

    func test_downFromTheEnvButton_reachesTheCarryList() throws {
        let dir = try makeRealDir()
        let ws = Workspace(title: "ZenTerm", path: dir, tabs: [], env: [:], carry: ["node_modules"])
        let (overlay, _) = mount(editing: ws)
        let carry = try XCTUnwrap(carryPicker(in: overlay))
        carry.settle = 0
        carry.probe = { _, _ in
            IgnoredCatalog(entries: ["node_modules"], resting: ["node_modules"], fileCounts: [:], directories: [])
        }
        let landed = expectation(description: "catalog")
        carry.onChanged = { if carry.focusStop != nil { landed.fulfill() } }
        typeFolder(dir.path, in: overlay)
        wait(for: [landed], timeout: 2)
        carry.onChanged = nil
        let list = try XCTUnwrap(carry.focusStop)
        let addVar = try XCTUnwrap(button(in: overlay, title: "＋ Add variable"))
        window?.makeFirstResponder(addVar)

        addVar.keyDown(with: try arrow(125, NSDownArrowFunctionKey))

        XCTAssertTrue(KeyboardFocus.isFocused(list, in: window))
    }

    func test_downFromTheFolder_walksTheDrawingTopToBottom_thenTheTabStrip() throws {
        let (overlay, _) = mount()
        let drawing = overlay.drawingForTesting
        window?.makeFirstResponder(picker(in: overlay).field.field)

        try XCTUnwrap(editor).keyDown(with: try arrow(125, NSDownArrowFunctionKey))
        XCTAssertTrue(KeyboardFocus.isFocused(try XCTUnwrap(drawing.region(.main)).field, in: window))

        try XCTUnwrap(editor).keyDown(with: try arrow(125, NSDownArrowFunctionKey))
        let bottom = try XCTUnwrap(drawing.stop(for: .bottom))
        XCTAssertIdentical(window?.firstResponder, bottom)

        bottom.keyDown(with: try arrow(125, NSDownArrowFunctionKey))
        XCTAssertIdentical(window?.firstResponder, overlay.tabStripForTesting.chips[0])

        overlay.tabStripForTesting.chips[0].keyDown(with: try arrow(126, NSUpArrowFunctionKey))
        XCTAssertIdentical(window?.firstResponder, bottom, "up from the strip lands on the row right above it")
    }

    func test_rightFromTheName_reachesTheFolder() throws {
        let (overlay, _) = mount()
        window?.makeFirstResponder(overlay.titleFieldForTesting.field)

        try XCTUnwrap(editor).keyDown(with: try arrow(124, NSRightArrowFunctionKey))

        XCTAssertTrue(KeyboardFocus.isFocused(picker(in: overlay).field.field, in: window))
    }

    func test_escape_cancelsTheForm() throws {
        let (overlay, sink) = mount()
        window!.makeFirstResponder(overlay.titleFieldForTesting.field)

        XCTAssertTrue(window!.contentView!.performKeyEquivalent(with: try escapeKey()))

        XCTAssertEqual(sink.cancelled, 1)
    }

    func test_escape_whileRenamingATab_cancelsOnlyTheRename() throws {
        let (overlay, sink) = mount()
        overlay.tabStripForTesting.beginRenamingSelected()

        XCTAssertTrue(window!.contentView!.performKeyEquivalent(with: try escapeKey()))

        XCTAssertEqual(sink.cancelled, 0)
        XCTAssertFalse(overlay.tabStripForTesting.isRenaming)
    }

    func test_folderChooseButton_opensThePicker_andIsArrowReachable() throws {
        let (overlay, _) = mount()
        var opened = false
        picker(in: overlay).presentPanel = { _, _, _ in opened = true }
        let choose = try XCTUnwrap(button(in: overlay, title: "Choose"))

        choose.onTap()
        XCTAssertTrue(opened)

        window?.makeFirstResponder(picker(in: overlay).field.field)
        picker(in: overlay).field.onArrowRight?()
        XCTAssertTrue(KeyboardFocus.isFocused(choose, in: window))
    }

    func test_theCard_growsPastTheOtherFormsBeforeItScrolls_andNoFurther() throws {
        let ws = Workspace(
            title: "Big", path: try makeRealDir(),
            tabs: [Workspace.Tab(main: "nvim", right: "claude", bottom: "shell")],
            env: Dictionary(uniqueKeysWithValues: (0..<12).map { ("KEY\($0)", "v") }),
            carry: (0..<20).map { "entry-\($0)" })
        let (overlay, _) = mount(editing: ws)

        let card = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? CardView }.first)
        XCTAssertEqual(card.frame.height, WorkspaceFormOverlay.maxHeight, accuracy: 0.5)
        XCTAssertEqual(card.frame.width, WorkspaceFormOverlay.width, accuracy: 0.5)
        XCTAssertGreaterThan(WorkspaceFormOverlay.maxHeight, FormCard.maxHeight)
    }
}
