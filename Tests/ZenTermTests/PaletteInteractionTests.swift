import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the ⌘P command palette and ⌘⇧P repo picker (ZEN-103) — the open/type/
/// arrow/choose path the recolor tests never touched. Drives the real `PaletteOverlay` keyboard
/// seams (`controlTextDidChange`, `control(_:textView:doCommandBy:)`) and asserts the activation
/// payload, exactly the Dropdown lesson: state plumbing exists, the choose path was unverified.
///
/// `NSApp.currentEvent` is nil in a test, so the Return handler can't read live modifiers —
/// the Shift+Enter (replace) path is driven through the `activate(index:modifiers:)` seam directly.
final class PaletteInteractionTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The overlay's search field, reached by walking the live view tree. Matched by
    /// `delegate === overlay` (the overlay is its field delegate) so it can't pick up some other
    /// editable field, and failing the test with a clear message rather than crashing the whole
    /// suite on a hierarchy change.
    private func searchField(
        in overlay: PaletteOverlay, file: StaticString = #filePath, line: UInt = #line
    ) -> NSTextField {
        guard
            let field = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.delegate === overlay })
        else {
            XCTFail("no search field (delegated to the overlay) found", file: file, line: line)
            return NSTextField()  // detached — keeps the suite alive; the XCTFail above is the failure
        }
        return field
    }

    /// Type `query` into the search field and fire the filter, exactly as AppKit would.
    private func type(_ query: String, into overlay: PaletteOverlay) {
        let field = searchField(in: overlay)
        field.stringValue = query
        overlay.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// Send an editing command (arrow / Return / Esc) through the overlay's field-editor hook.
    @discardableResult
    private func send(_ selector: Selector, to overlay: PaletteOverlay) -> Bool {
        overlay.control(searchField(in: overlay), textView: NSTextView(), doCommandBy: selector)
    }

    private func mount(_ overlay: PaletteOverlay) {
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
    }

    private static let moveDown = #selector(NSResponder.moveDown(_:))
    private static let moveUp = #selector(NSResponder.moveUp(_:))
    private static let insertNewline = #selector(NSResponder.insertNewline(_:))
    private static let cancel = #selector(NSResponder.cancelOperation(_:))

    // MARK: command palette

    /// Grouped layout: [header Panes, Split(1), Close(2), header Tabs, New Tab(4)].
    private func makeCommandPalette(
        onRun: @escaping (KeyInterceptor.ReservedChord) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) -> CommandPaletteOverlay {
        let commands = [
            PaletteCommand(title: "Split Vertically", shortcut: "⌘D", category: "Panes", chord: .splitVertical),
            PaletteCommand(title: "Close Pane", shortcut: "⌘W", category: "Panes", chord: .closePane),
            PaletteCommand(title: "New Tab", shortcut: "⌘T", category: "Tabs", chord: .newTab),
        ]
        return CommandPaletteOverlay(
            commands: commands, background: Theme.current.chrome.background.nsColor,
            onRun: onRun, onDismiss: onDismiss)
    }

    func test_commandPalette_returnRunsFirstCommandSkippingHeader() {
        var ran: KeyInterceptor.ReservedChord?
        let overlay = makeCommandPalette(onRun: { ran = $0 })
        mount(overlay)
        // Default selection is the first *selectable* row (index 1), never the "Panes" header.
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .splitVertical)
    }

    func test_commandPalette_arrowDownSkipsTheHeaderBetweenGroups() {
        var ran: KeyInterceptor.ReservedChord?
        let overlay = makeCommandPalette(onRun: { ran = $0 })
        mount(overlay)
        // From Split(1): down → Close(2); down → skips the "Tabs" header(3) → New Tab(4).
        send(Self.moveDown, to: overlay)
        send(Self.moveDown, to: overlay)
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .newTab)
    }

    func test_commandPalette_filterFlattensAndFuzzyRanks() {
        var ran: KeyInterceptor.ReservedChord?
        let overlay = makeCommandPalette(onRun: { ran = $0 })
        mount(overlay)
        type("close", into: overlay)
        // Filtered list is flat (no headers) — only "Close Pane" matches.
        XCTAssertEqual(overlay.numberOfRows(), 1)
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .closePane)
    }

    func test_commandPalette_searchingSectionName_surfacesTheWholeSection() {
        let overlay = makeCommandPalette()
        mount(overlay)
        // "panes" isn't in either Panes command's title — it matches their category, so both surface
        // while the Tabs command ("New Tab") is filtered out.
        type("panes", into: overlay)
        XCTAssertEqual(overlay.numberOfRows(), 2, "the section name surfaces every command in that section")
    }

    func test_commandPalette_titleMatchOutranksCategoryOnlyMatch() {
        var ran: KeyInterceptor.ReservedChord?
        let commands = [
            PaletteCommand(title: "Open Settings", shortcut: "⌘,", category: "Config", chord: .openSettings),
            PaletteCommand(title: "Close Pane", shortcut: "⌘W", category: "Panes", chord: .closePane),
        ]
        let overlay = CommandPaletteOverlay(
            commands: commands, background: Theme.current.chrome.background.nsColor,
            onRun: { ran = $0 }, onDismiss: {})
        mount(overlay)
        // "con" fuzzy-matches the "Config" category (surfacing Open Settings, whose title has no
        // match) AND the "Close Pane" title. The title hit must take the top row so Enter runs the
        // command the query named, not the higher-scoring category-only match.
        type("con", into: overlay)
        XCTAssertEqual(overlay.numberOfRows(), 2, "Close Pane by title, Open Settings by category")
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .closePane)
    }

    func test_commandPalette_escDismisses() {
        var dismissed = false
        let overlay = makeCommandPalette(onDismiss: { dismissed = true })
        mount(overlay)
        XCTAssertTrue(send(Self.cancel, to: overlay))
        XCTAssertTrue(dismissed)
    }

    // MARK: repo picker

    private func workspace(_ title: String) -> Workspace {
        Workspace(
            title: title, path: FileManager.default.temporaryDirectory, main: nil, right: nil,
            bottom: nil, focus: .main, env: [:])
    }

    private func makeRepoPicker(
        entries: [Workspace],
        onChoose: @escaping (Workspace, Bool) -> Void = { _, _ in },
        onAddWorkspace: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {}
    ) -> RepoPickerOverlay {
        RepoPickerOverlay(
            entries: entries, background: Theme.current.chrome.background.nsColor,
            onChoose: onChoose, onAddWorkspace: onAddWorkspace, onDismiss: onDismiss)
    }

    func test_repoPicker_returnOpensFirstWorkspaceNotTheAddRow() {
        var chosen: (Workspace, Bool)?
        var addOpened = false
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")],
            onChoose: { chosen = ($0, $1) }, onAddWorkspace: { addOpened = true })
        mount(overlay)
        // Default selection is the first workspace (index 1), not the pinned ＋ row (index 0).
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(chosen?.0.title, "alpha")
        XCTAssertEqual(chosen?.1, false)
        XCTAssertFalse(addOpened)
    }

    func test_repoPicker_shiftEnterReplacesCurrentTab() {
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(entries: [workspace("alpha")], onChoose: { chosen = ($0, $1) })
        mount(overlay)
        // Shift is a live modifier the Return field-editor hook can't see in a test — drive the
        // activation seam it routes to, index 1 = the first workspace.
        overlay.activate(index: 1, modifiers: .shift)
        XCTAssertEqual(chosen?.0.title, "alpha")
        XCTAssertEqual(chosen?.1, true)
    }

    func test_repoPicker_upArrowReachesAddRowAndActivatesIt() {
        var chosen: (Workspace, Bool)?
        var addOpened = false
        let overlay = makeRepoPicker(
            entries: [workspace("alpha")],
            onChoose: { chosen = ($0, $1) }, onAddWorkspace: { addOpened = true })
        mount(overlay)
        // From the first workspace (index 1), up → the ＋ row (index 0). Return opens the form.
        send(Self.moveUp, to: overlay)
        send(Self.insertNewline, to: overlay)
        XCTAssertTrue(addOpened)
        XCTAssertNil(chosen)
    }

    func test_repoPicker_filterNarrowsWorkspacesKeepingAddRowPinned() {
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")], onChoose: { chosen = ($0, $1) })
        mount(overlay)
        type("bet", into: overlay)
        // ＋ row (0) stays pinned; only "beta" matches → 2 rows. Return opens the sole match.
        XCTAssertEqual(overlay.numberOfRows(), 2)
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(chosen?.0.title, "beta")
    }
}
