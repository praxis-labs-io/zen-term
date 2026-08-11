import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the ⌘P command palette and ⌘⇧P repo picker — the open/type/
/// arrow/choose path the recolor tests never touched. Drives the real `PaletteOverlay` keyboard
/// seams (`controlTextDidChange`, `control(_:textView:doCommandBy:)`) and asserts the activation
/// payload, exactly the Dropdown lesson: state plumbing exists, the choose path was unverified.
///
/// The Return handler reads live modifiers off `NSApp.currentEvent`, which a test does not control
/// by default: it holds whatever AppKit last dequeued. Every Return goes through `sendReturn`,
/// which pins the event first, so both the plain ⏎ and the ⇧⏎ replace path assert what they say
/// they do.
final class PaletteInteractionTests: WindowTestCase {
    /// Retained so a mounted overlay's window outlives the mount call (Esc is dispatched through it).
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

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

    /// Return, with `NSApp.currentEvent` pinned to the ⏎ the hook is about to read.
    ///
    /// The Return hook reads live modifiers off `NSApp.currentEvent`, which holds whatever AppKit
    /// last dequeued for this process. A test that rests on it being nil rests on the order the
    /// suite happened to run in. Dequeuing the keystroke is also what production does:
    /// the Return the user pressed is the current event when the hook runs.
    private func sendReturn(
        to overlay: PaletteOverlay, modifiers: NSEvent.ModifierFlags = []
    ) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: true)
        // Checked by value, because the queue hands back a copy rather than the posted object. An
        // empty queue dequeues nothing and leaves the hook reading whatever an earlier case left,
        // which is the failure this helper exists to prevent.
        let pinned = try XCTUnwrap(NSApp.currentEvent, "nothing dequeued, so the pin did not take")
        XCTAssertEqual(pinned.keyCode, 36)
        XCTAssertEqual(
            pinned.modifierFlags.intersection([.command, .shift, .option, .control]), modifiers,
            "the dequeued Return carries modifiers this test did not ask for")
        send(Self.insertNewline, to: overlay)
    }

    @discardableResult
    private func mount(_ overlay: PaletteOverlay) -> NSWindow {
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        self.window = window
        return window
    }

    /// Press Esc the way `NSWindow.sendEvent` does — a `performKeyEquivalent` traversal of the
    /// contentView subtree, which is where the card root claims it.
    @discardableResult
    private func pressEscape(in window: NSWindow) -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window.contentView!.performKeyEquivalent(with: esc)
    }

    /// The selectable (non-header) rows currently laid out, in list order.
    private func rows(in overlay: PaletteOverlay) -> [SelectableRowView] {
        descendants(of: overlay).compactMap { $0 as? SelectableRowView }
    }

    /// The list stack — the one whose arranged subviews are the rows. What the list SHOWS is its
    /// arranged order, and a reused row keeps its old place in `subviews`, so walking the view tree
    /// stops telling you the display order the moment rows are reused.
    private func rowsStack(
        in overlay: PaletteOverlay, file: StaticString = #filePath, line: UInt = #line
    ) -> NSStackView {
        guard
            let stack = descendants(of: overlay).compactMap({ $0 as? NSStackView })
                .first(where: { $0.arrangedSubviews.contains { $0 is PaletteRowView } })
        else {
            XCTFail("no row stack found", file: file, line: line)
            return NSStackView()
        }
        return stack
    }

    /// Drive the row's real mouseDown/mouseUp with real `NSEvent`s (not its backing state), which is
    /// where the single-click activation logic lives. `landingInside` places the release inside the
    /// row or well outside it, to drive a normal click vs a drag-off.
    ///
    /// This calls the row directly rather than routing through `window.sendEvent`: dispatching a
    /// synthetic click to a headless, off-screen window isn't hit-tested to the row, and the only
    /// way to make routing work — a real key window ordered on screen — reintroduces the very
    /// panel/window flashing these tests avoid. That the OS routes a click through the scroll/clip
    /// view to the row is AppKit's job, not ours; the single-click behavior actually landing is a
    /// look-don't-assert runbook step (`swift run ZenTerm`).
    private func click(_ row: SelectableRowView, landingInside: Bool = true) {
        let inside = CGPoint(x: row.bounds.midX, y: row.bounds.midY)
        let outside = CGPoint(x: row.bounds.maxX + 400, y: row.bounds.midY)
        func event(_ type: NSEvent.EventType, _ local: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: row.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)!
        }
        row.mouseDown(with: event(.leftMouseDown, inside))
        row.mouseUp(with: event(.leftMouseUp, landingInside ? inside : outside))
    }

    private static let moveDown = #selector(NSResponder.moveDown(_:))
    private static let moveUp = #selector(NSResponder.moveUp(_:))
    private static let insertNewline = #selector(NSResponder.insertNewline(_:))

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
            commands: { commands }, background: Theme.current.chrome.background.nsColor,
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

    func test_commandPalette_singleClickRunsTheRow() {
        var ran: KeyInterceptor.ReservedChord?
        let overlay = makeCommandPalette(onRun: { ran = $0 })
        let window = mount(overlay)
        window.layoutIfNeeded()
        // First selectable row = Split Vertically (the "Panes" header isn't a SelectableRowView).
        click(rows(in: overlay)[0])
        XCTAssertEqual(ran, .splitVertical, "a single click must run the row, no double-click")
    }

    func test_commandPalette_pressThenDragOff_doesNotRun() {
        var ran: KeyInterceptor.ReservedChord?
        let overlay = makeCommandPalette(onRun: { ran = $0 })
        let window = mount(overlay)
        window.layoutIfNeeded()
        click(rows(in: overlay)[0], landingInside: false)
        XCTAssertNil(ran, "releasing off the row cancels, like a button drag-off")
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
            commands: { commands }, background: Theme.current.chrome.background.nsColor,
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

    // MARK: scrolling as the selection moves

    /// Two groups of twelve: past the 320pt list, so the selection has to scroll.
    private func makeLongCommandPalette() -> CommandPaletteOverlay {
        let commands =
            (0..<12).map {
                PaletteCommand(
                    title: "Pane action \($0)", shortcut: "⌘\($0)", category: "Panes", chord: .splitVertical)
            }
            + (0..<12).map {
                PaletteCommand(
                    title: "Tab action \($0)", shortcut: "⌥\($0)", category: "Tabs", chord: .newTab)
            }
        return CommandPaletteOverlay(
            commands: { commands }, background: Theme.current.chrome.background.nsColor,
            onRun: { _ in }, onDismiss: {})
    }

    private func mountLongPalette() throws -> (CommandPaletteOverlay, NSScrollView) {
        let overlay = makeLongCommandPalette()
        let window = mount(overlay)
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(
            scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height,
            "expected a list taller than the palette")
        return (overlay, scroll)
    }

    private func isFullyVisible(_ view: NSView, in scroll: NSScrollView) throws -> Bool {
        let document = try XCTUnwrap(scroll.documentView)
        return scroll.documentVisibleRect.contains(view.convert(view.bounds, to: document))
    }

    /// Scrolling to the selected row alone left the header naming its group just above the visible
    /// top, so arrowing up into Tabs showed its commands with no "Tabs" over them.
    func test_commandPalette_arrowingUpIntoAGroup_showsTheHeaderNamingIt() throws {
        let (overlay, scroll) = try mountLongPalette()
        let views = overlay.rowViews
        let headers = views.enumerated().filter { !($0.element is SelectableRowView) }
        let tabs = try XCTUnwrap(headers.dropFirst().first, "expected a second section header")
        let firstOfGroup = views[tabs.offset + 1]

        for _ in views.indices { send(Self.moveDown, to: overlay) }  // to the bottom of the list
        XCTAssertFalse(try isFullyVisible(tabs.element, in: scroll), "the list has to be scrolled first")
        while !firstOfGroup.isSelected { send(Self.moveUp, to: overlay) }

        XCTAssertTrue(
            try isFullyVisible(tabs.element, in: scroll),
            "the group's first command comes with the header above it")
    }

    func test_commandPalette_arrowingDown_leavesRoomBelowTheSelection() throws {
        let (overlay, scroll) = try mountLongPalette()
        let document = try XCTUnwrap(scroll.documentView)

        for _ in 0..<10 { send(Self.moveDown, to: overlay) }

        let selected = try XCTUnwrap(overlay.rowViews.first { $0.isSelected })
        let gap = scroll.documentVisibleRect.maxY - selected.convert(selected.bounds, to: document).maxY
        XCTAssertGreaterThan(gap, 24, "the selection lands inside the list, not flush against the edge")
    }

    /// The palette reveals its default selection while it builds its rows, which is before the card has
    /// a size. Reading the reveal's rules against a zero-height viewport scrolled the list to that row's
    /// bottom edge, so ⌘P opened part-way down its own list with the selection above the fold.
    func test_commandPalette_opensAtTheTopOfItsList() throws {
        let (_, scroll) = try mountLongPalette()

        XCTAssertEqual(
            scroll.documentVisibleRect.minY, 0, accuracy: 0.5,
            "a freshly opened palette shows its first command, not the middle of the list")
    }

    /// Arrowing back to the top has to reach it. Revealing the first command alone left the header
    /// above it and the list's top inset clipped, with the scroller parked just short of the top.
    func test_commandPalette_arrowingBackToTheTop_reachesIt() throws {
        let (overlay, scroll) = try mountLongPalette()

        for _ in overlay.rowViews.indices { send(Self.moveDown, to: overlay) }
        for _ in overlay.rowViews.indices { send(Self.moveUp, to: overlay) }

        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 0.5, "the first command opens at the top")
    }

    /// Esc dismisses from the search field — the palette's initial first responder. Driven through
    /// the real key-equivalent traversal, since Esc moved from the field editor's
    /// `cancelOperation` up to the card root, where every card now owns it.
    func test_commandPalette_escDismisses() {
        var dismissed = false
        let overlay = makeCommandPalette(onDismiss: { dismissed = true })
        let window = mount(overlay)
        window.makeFirstResponder(searchField(in: overlay))

        XCTAssertTrue(pressEscape(in: window), "the card root must claim Esc")

        XCTAssertTrue(dismissed)
    }

    // MARK: repo picker

    private func workspace(_ title: String, path: URL = FileManager.default.temporaryDirectory) -> Workspace {
        Workspace(
            title: title, path: path, main: nil, right: nil,
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

    func test_repoPicker_returnOpensFirstWorkspaceNotTheAddRow() throws {
        var chosen: (Workspace, Bool)?
        var addOpened = false
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")],
            onChoose: { chosen = ($0, $1) }, onAddWorkspace: { addOpened = true })
        mount(overlay)
        // Default selection is the first workspace (index 1), not the pinned ＋ row (index 0).
        try sendReturn(to: overlay)
        XCTAssertEqual(chosen?.0.title, "alpha")
        XCTAssertEqual(chosen?.1, false)
        XCTAssertFalse(addOpened)
    }

    func test_repoPicker_shiftEnterReplacesCurrentTab() throws {
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(entries: [workspace("alpha")], onChoose: { chosen = ($0, $1) })
        mount(overlay)
        // Through the field-editor hook, so the ⇧ the hook lifts off the current event is covered.
        try sendReturn(to: overlay, modifiers: .shift)
        XCTAssertEqual(chosen?.0.title, "alpha")
        XCTAssertEqual(chosen?.1, true)
    }

    func test_repoPicker_upArrowReachesAddRowAndActivatesIt() throws {
        var chosen: (Workspace, Bool)?
        var addOpened = false
        let overlay = makeRepoPicker(
            entries: [workspace("alpha")],
            onChoose: { chosen = ($0, $1) }, onAddWorkspace: { addOpened = true })
        mount(overlay)
        // From the first workspace (index 1), up → the ＋ row (index 0). Return opens the form.
        send(Self.moveUp, to: overlay)
        try sendReturn(to: overlay)
        XCTAssertTrue(addOpened)
        XCTAssertNil(chosen)
    }

    // MARK: row reuse

    /// Typing re-renders the list, and a row whose identity survives the filter keeps its view
    /// instead of being rebuilt. The list is then ordered by the ARRANGED subviews, not the view
    /// tree: a reused row stays where it was in `subviews` and only moves in the arrangement.
    func test_repoPicker_reusedRows_keepTheirViewsAndFollowTheFilterOrder() {
        // Config order [zeta, alpha]; typing "a" matches both (zeta ends in one) and ranks the
        // prefix match first, so both rows are reused AND swap places.
        let overlay = makeRepoPicker(entries: [workspace("zeta"), workspace("alpha")])
        mount(overlay)
        let (addRow, zetaRow, alphaRow) = (rows(in: overlay)[0], rows(in: overlay)[1], rows(in: overlay)[2])

        type("a", into: overlay)

        XCTAssertEqual(
            rowsStack(in: overlay).arrangedSubviews, [addRow, alphaRow, zetaRow],
            "every row is reused, re-ordered by the filter rather than rebuilt")
    }

    /// The sharp edge of reuse: a row's click closure is bound to an index, and a reused row sits at
    /// a NEW index after a filter. Rebinding on every load is what keeps a click running the row the
    /// user is pointing at rather than whatever now occupies the index it was built at.
    func test_repoPicker_clickingAReusedRow_runsWhereItNowSits() {
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")], onChoose: { chosen = ($0, $1) })
        let window = mount(overlay)
        window.layoutIfNeeded()
        let betaRow = rows(in: overlay)[2]  // [＋(0), alpha(1), beta(2)]

        type("bet", into: overlay)  // → [＋(0), beta(1)]: beta's view moves down one
        window.layoutIfNeeded()

        XCTAssertTrue(rows(in: overlay).contains { $0 === betaRow }, "beta's row must be the reused one")
        click(betaRow)
        XCTAssertEqual(chosen?.0.title, "beta", "a reused row runs its current index, not the one it was built at")
    }

    /// A tool float's title comes from the user's config and nothing stops it matching a built-in
    /// command's, so two rows can share a title while rendering different chords. The keycap beside
    /// a command has to be the chord that runs it, whichever row the filter reuses.
    func test_commandPalette_commandsSharingATitle_keepTheirOwnShortcut() {
        var ran: KeyInterceptor.ReservedChord?
        let shortcuts: [KeyInterceptor.ReservedChord: String] = [.newTab: "⌘T", .toggleToolFloat("nt"): "⌘⇧J"]
        let overlay = CommandPaletteOverlay(
            commands: {
                [
                    PaletteCommand(title: "New Tab", shortcut: "⌘T", category: "Tabs", chord: .newTab),
                    PaletteCommand(
                        title: "New Tab", shortcut: "⌘⇧J", category: "Tools",
                        chord: .toggleToolFloat("nt")),
                ]
            },
            background: Theme.current.chrome.background.nsColor, onRun: { ran = $0 }, onDismiss: {})
        let window = mount(overlay)
        window.layoutIfNeeded()

        type("new", into: overlay)  // both match, and both rows carry the same title
        window.layoutIfNeeded()

        // Assert per row rather than by list position: which of the two sorts first is not the
        // claim, and Swift's sort isn't stable on equal keys.
        XCTAssertEqual(rows(in: overlay).count, 2)
        for row in rows(in: overlay) {
            let rendered = descendants(of: row).compactMap { ($0 as? KeycapView)?.shortcut }
            click(row)
            XCTAssertEqual(
                rendered, [ran.flatMap { shortcuts[$0] }].compactMap { $0 },
                "the keycap on a row must be the chord that row runs")
        }
    }

    func test_commandPalette_reusesTheRowOfACommandThatSurvivesTheFilter() {
        let overlay = makeCommandPalette()
        mount(overlay)
        let closeRow = rows(in: overlay)[1]  // [Split(0), Close(1), New Tab(2)] — headers aren't selectable

        type("close", into: overlay)

        XCTAssertEqual(rows(in: overlay).count, 1)
        XCTAssertTrue(rows(in: overlay)[0] === closeRow, "the surviving command keeps its row view")
    }

    /// Rows bake their colors in at construction, so the reuse index has to be dropped on a theme
    /// swap — reusing a row there would leave the whole list in the old palette.
    func test_reapplyTheme_rebuildsRowsRatherThanReusingStaleColors() {
        let overlay = makeCommandPalette()
        mount(overlay)
        let before = rows(in: overlay)

        overlay.reapplyTheme()

        let after = rows(in: overlay)
        XCTAssertEqual(after.count, before.count)
        XCTAssertTrue(
            zip(before, after).allSatisfy { $0 !== $1 },
            "a theme swap must rebuild every row, not reuse one carrying the old palette")
    }

    /// The badge asks a filesystem question that can't be answered on the main thread, so the row
    /// renders first and the badge lands when the probe does.
    func test_repoPicker_gitBadgeAppearsWhenTheBackgroundProbeLands() throws {
        GitRepoStatus.resetForTesting()
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent(".git"))  // a worktree-style `.git` file
        defer { try? FileManager.default.removeItem(at: repo) }

        let overlay = makeRepoPicker(entries: [workspace("repo", path: repo)])
        mount(overlay)
        let badge = descendants(of: rows(in: overlay)[1]).compactMap { $0 as? NSImageView }.first
        XCTAssertEqual(badge?.isHidden, true, "nothing has probed the folder yet")

        waitUntil(badge?.isHidden == false, "the git badge to turn on when the probe lands")

        XCTAssertNotNil(badge?.image, "and renders the bundled git logo")
    }

    func test_repoPicker_filterNarrowsWorkspacesKeepingAddRowPinned() throws {
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")], onChoose: { chosen = ($0, $1) })
        mount(overlay)
        type("bet", into: overlay)
        // ＋ row (0) stays pinned; only "beta" matches → 2 rows. Return opens the sole match.
        XCTAssertEqual(overlay.numberOfRows(), 2)
        try sendReturn(to: overlay)
        XCTAssertEqual(chosen?.0.title, "beta")
        XCTAssertEqual(chosen?.1, false)
    }
}
