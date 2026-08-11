import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the Tools settings section: mount the real section over a
/// sandboxed config, assert it renders a row per configured float, that add / edit route out
/// through `onEditFloat`, and that remove writes the config and drops the row. The write→reload
/// roundtrip is sandboxed via `ConfigLoader.defaultRootOverrideForTesting`.
final class SettingsToolsSectionTests: WindowTestCase {
    /// Records the float `onEditFloat` was invoked with (`nil` = add).
    private final class EditSink {
        var calls: [ToolFloat?] = []
    }

    private var tempRoot: URL!
    private var window: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        window = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @discardableResult
    private func mount(_ section: SettingsToolsSection) -> NSView {
        let detail = section.makeDetailView()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(detail)
        detail.frame = win.contentView!.bounds
        window = win
        return detail
    }

    private func rows(in view: NSView) -> [ToolFloatRow] {
        descendants(of: view).compactMap { $0 as? ToolFloatRow }
    }

    private let twoFloats = """
        float = title:dev key:cmd+shift+d command:vim
        float = title:top key:cmd+shift+t command:htop
        """

    /// An arrow keyDown, built the way AppKit really delivers one.
    ///
    /// `.function` and `.numericPad` are NOT decoration: macOS sets both on every arrow event, and
    /// omitting them is how the first cut of this test passed against a reorder that was dead in the
    /// app — the code masked with `deviceIndependentFlagsMask`, which keeps those bits, and compared
    /// for equality with `.option`. A synthesized event has to carry them or it isn't testing the
    /// keystroke the user actually makes.
    private func arrow(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union([.function, .numericPad]),
            timestamp: 0, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }

    private var optionDown: NSEvent { arrow(125, .option) }
    private var optionUp: NSEvent { arrow(126, .option) }

    /// The section defers its write to the next runloop turn (it rebuilds the very row whose `keyDown`
    /// is still on the stack), so a test has to let that turn happen before asserting.
    private func settleReorder() {
        let done = expectation(description: "reorder applied")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// Wire the section to the same write the host uses, so these tests cover the real path rather
    /// than a test-local imitation of it.
    private func wireReorder(_ section: SettingsToolsSection) {
        section.onReorder = { floats in
            try? ConfigWriter.applyFloatOrder(floats)
            AppConfig.reload()
        }
    }

    private func configuredFloatIDs() -> [String] {
        GeneralConfig.current.floats.map(\.id)
    }

    // MARK: tests

    func test_rendersRowPerConfiguredFloat() throws {
        try seed(twoFloats)
        let detail = mount(SettingsToolsSection())
        XCTAssertEqual(rows(in: detail).map(\.float.id), ["dev", "top"])
    }

    func test_row_drawsTheLiveShortcut() throws {
        try seed(twoFloats)
        let detail = mount(SettingsToolsSection())
        XCTAssertEqual(rows(in: detail).map(\.renderedShortcutForTesting), ["⌘⇧D", "⌘⇧T"])
    }

    /// The float survives a `key:` the menu owns; only its chord is refused. The row used to build a
    /// keycap regardless, so an empty glyph drew an empty pill: a shortcut cell that says nothing at
    /// all. Settings is where you go to fix the config, so the absence has to be stated.
    func test_row_aMenuOwnedKey_readsAsUnset() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer {
            NSApp.mainMenu = previous
            AppConfig.reload()
        }
        MainMenu.install()

        try seed("float = title:dev key:cmd+q command:vim")
        let detail = mount(SettingsToolsSection())

        let row = try XCTUnwrap(rows(in: detail).first)
        XCTAssertEqual(row.float.toggle, Chord(command: true, key: "q"), "the raw config value survives")
        XCTAssertEqual(row.renderedShortcutForTesting, "Not set")
    }

    func test_emptyConfig_showsOnlyAddButtonStop() throws {
        try seed("")
        let section = SettingsToolsSection()
        let detail = mount(section)
        XCTAssertTrue(rows(in: detail).isEmpty)
        XCTAssertEqual(section.detailStops().count, 1, "empty state exposes only the add button")
        XCTAssertTrue(section.detailStops().first is AppButton)
    }

    func test_addButton_invokesOnEditFloatWithNil() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        let sink = EditSink()
        section.onEditFloat = { sink.calls.append($0) }
        _ = mount(section)

        (section.detailStops().last as? AppButton)?.onTap()

        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertNil(sink.calls.first ?? nil, "the add button adds a new float (nil)")
    }

    func test_rowActivate_invokesOnEditFloatWithThatFloat() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        let sink = EditSink()
        section.onEditFloat = { sink.calls.append($0) }
        let detail = mount(section)

        rows(in: detail).first { $0.float.id == "top" }?.onActivate?()

        XCTAssertEqual(sink.calls.first??.id, "top")
    }

    // MARK: reorder

    /// ⌥↓ moves the float itself and persists it. Asserted through the config file, because that's the
    /// thing the dock and ⌘P re-read — a row list that reordered without the write would look right
    /// and revert on relaunch.
    func test_optionDown_movesFloatDown_andPersists() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        wireReorder(section)
        let detail = mount(section)

        rows(in: detail).first { $0.float.id == "dev" }?.keyDown(with: optionDown)
        settleReorder()

        XCTAssertEqual(configuredFloatIDs(), ["top", "dev"])
        XCTAssertEqual(rows(in: detail).map(\.float.id), ["top", "dev"], "the rebuilt rows show the new order")
    }

    func test_optionUp_movesFloatUp_andPersists() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        wireReorder(section)
        let detail = mount(section)

        rows(in: detail).first { $0.float.id == "top" }?.keyDown(with: optionUp)
        settleReorder()

        XCTAssertEqual(configuredFloatIDs(), ["top", "dev"])
    }

    /// Focus has to ride along with the float, or ⌥↓⌥↓ would walk a *different* float down on the
    /// second press — the rows are rebuilt from scratch, so the focused view is a brand new object.
    func test_reorder_keepsFocusOnTheMovedRow() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        wireReorder(section)
        let detail = mount(section)
        let dev = try XCTUnwrap(rows(in: detail).first { $0.float.id == "dev" })
        window?.makeFirstResponder(dev)

        dev.keyDown(with: optionDown)
        settleReorder()

        let focused = window?.firstResponder as? ToolFloatRow
        XCTAssertEqual(focused?.float.id, "dev", "focus follows the float that moved, not the slot")
    }

    /// ⌥↑ on the first row is a no-op, not a wrap: a float silently teleporting to the far end of the
    /// dock is worse than nothing happening.
    func test_optionUp_atTop_doesNothing() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        wireReorder(section)
        let detail = mount(section)

        rows(in: detail).first { $0.float.id == "dev" }?.keyDown(with: optionUp)
        settleReorder()

        XCTAssertEqual(configuredFloatIDs(), ["dev", "top"])
    }

    /// Plain Up/Down must still move focus rather than reorder — the modifier is the whole difference,
    /// and `KeyboardFocus.key(for:)` decodes the keyCode without looking at it.
    func test_plainArrow_movesFocus_withoutReordering() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        wireReorder(section)
        let detail = mount(section)
        let dev = try XCTUnwrap(rows(in: detail).first { $0.float.id == "dev" })
        window?.makeFirstResponder(dev)

        dev.keyDown(with: arrow(125))  // bare Down — still carries .function/.numericPad
        settleReorder()

        XCTAssertEqual(configuredFloatIDs(), ["dev", "top"], "a bare Down must not reorder")
        XCTAssertEqual((window?.firstResponder as? ToolFloatRow)?.float.id, "top", "it moves focus instead")
    }

    /// ⌥⌘↓ is a different chord and must not reorder — the guard is "Option and nothing else", which a
    /// plain `contains(.option)` would get wrong in the other direction.
    func test_optionCommandArrow_doesNotReorder() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        wireReorder(section)
        let detail = mount(section)

        rows(in: detail).first { $0.float.id == "dev" }?.keyDown(with: arrow(125, [.option, .command]))
        settleReorder()

        XCTAssertEqual(configuredFloatIDs(), ["dev", "top"])
    }

    // MARK: reorder affordance

    /// ⌥↑/⌥↓ is otherwise undiscoverable — nothing on a row suggests a float can move.
    func test_reorderHint_shownOnlyWhenThereIsSomethingToReorder() throws {
        try seed(twoFloats)
        XCTAssertNotNil(hintLabel(in: mount(SettingsToolsSection())), "two floats → the hint is shown")

        try seed("float = title:dev key:cmd+shift+d command:vim")
        XCTAssertNil(
            hintLabel(in: mount(SettingsToolsSection())),
            "one float → no hint, rather than advertising a keystroke that would do nothing")
    }

    private func hintLabel(in view: NSView) -> NSTextField? {
        descendants(of: view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.localizedCaseInsensitiveContains("reorder") }
    }
}
