import AppKit
import XCTest

@testable import ZenTerm

final class PaletteInteractionTests: WindowTestCase {
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        GitRepoStatus.resetForTesting()
    }

    override func tearDown() {
        window = nil
        GitRepoStatus.resetForTesting()
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

    private func searchField(
        in overlay: PaletteOverlay, file: StaticString = #filePath, line: UInt = #line
    ) -> NSTextField {
        guard
            let field = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.delegate === overlay })
        else {
            XCTFail("no search field (delegated to the overlay) found", file: file, line: line)
            return NSTextField()
        }
        return field
    }

    private func type(_ query: String, into overlay: PaletteOverlay) {
        let field = searchField(in: overlay)
        field.stringValue = query
        overlay.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    @discardableResult
    private func send(_ selector: Selector, to overlay: PaletteOverlay) -> Bool {
        overlay.control(searchField(in: overlay), textView: NSTextView(), doCommandBy: selector)
    }

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

    @discardableResult
    private func pressEscape(in window: NSWindow) -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window.contentView!.performKeyEquivalent(with: esc)
    }

    private func rows(in overlay: PaletteOverlay) -> [SelectableRowView] {
        descendants(of: overlay).compactMap { $0 as? SelectableRowView }
    }

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
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .splitVertical)
    }

    func test_commandPalette_singleClickRunsTheRow() {
        var ran: KeyInterceptor.ReservedChord?
        let overlay = makeCommandPalette(onRun: { ran = $0 })
        let window = mount(overlay)
        window.layoutIfNeeded()
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
        XCTAssertEqual(overlay.numberOfRows(), 1)
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .closePane)
    }

    func test_commandPalette_searchingSectionName_surfacesTheWholeSection() {
        let overlay = makeCommandPalette()
        mount(overlay)
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
        type("con", into: overlay)
        XCTAssertEqual(overlay.numberOfRows(), 2, "Close Pane by title, Open Settings by category")
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .closePane)
    }

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

    func test_commandPalette_arrowingUpIntoAGroup_showsTheHeaderNamingIt() throws {
        let (overlay, scroll) = try mountLongPalette()
        let views = overlay.rowViews
        let headers = views.enumerated().filter { !($0.element is SelectableRowView) }
        let tabs = try XCTUnwrap(headers.dropFirst().first, "expected a second section header")
        let firstOfGroup = views[tabs.offset + 1]

        for _ in views.indices { send(Self.moveDown, to: overlay) }
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

    func test_commandPalette_opensAtTheTopOfItsList() throws {
        let (_, scroll) = try mountLongPalette()

        XCTAssertEqual(
            scroll.documentVisibleRect.minY, 0, accuracy: 0.5,
            "a freshly opened palette shows its first command, not the middle of the list")
    }

    func test_commandPalette_arrowingBackToTheTop_reachesIt() throws {
        let (overlay, scroll) = try mountLongPalette()

        for _ in overlay.rowViews.indices { send(Self.moveDown, to: overlay) }
        for _ in overlay.rowViews.indices { send(Self.moveUp, to: overlay) }

        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 0.5, "the first command opens at the top")
    }

    func test_commandPalette_escDismisses() {
        var dismissed = false
        let overlay = makeCommandPalette(onDismiss: { dismissed = true })
        let window = mount(overlay)
        window.makeFirstResponder(searchField(in: overlay))

        XCTAssertTrue(pressEscape(in: window), "the card root must claim Esc")

        XCTAssertTrue(dismissed)
    }

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
        try sendReturn(to: overlay)
        XCTAssertEqual(chosen?.0.title, "alpha")
        XCTAssertEqual(chosen?.1, false)
        XCTAssertFalse(addOpened)
    }

    func test_repoPicker_shiftEnterReplacesCurrentTab() throws {
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(entries: [workspace("alpha")], onChoose: { chosen = ($0, $1) })
        mount(overlay)
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
        send(Self.moveUp, to: overlay)
        try sendReturn(to: overlay)
        XCTAssertTrue(addOpened)
        XCTAssertNil(chosen)
    }

    func test_repoPicker_reusedRows_keepTheirViewsAndFollowTheFilterOrder() {
        let overlay = makeRepoPicker(entries: [workspace("zeta"), workspace("alpha")])
        mount(overlay)
        let (addRow, zetaRow, alphaRow) = (rows(in: overlay)[0], rows(in: overlay)[1], rows(in: overlay)[2])

        type("a", into: overlay)

        XCTAssertEqual(
            rowsStack(in: overlay).arrangedSubviews, [addRow, alphaRow, zetaRow],
            "every row is reused, re-ordered by the filter rather than rebuilt")
    }

    func test_repoPicker_clickingAReusedRow_runsWhereItNowSits() {
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")], onChoose: { chosen = ($0, $1) })
        let window = mount(overlay)
        window.layoutIfNeeded()
        let betaRow = rows(in: overlay)[2]

        type("bet", into: overlay)
        window.layoutIfNeeded()

        XCTAssertTrue(rows(in: overlay).contains { $0 === betaRow }, "beta's row must be the reused one")
        click(betaRow)
        XCTAssertEqual(chosen?.0.title, "beta", "a reused row runs its current index, not the one it was built at")
    }

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

        type("new", into: overlay)
        window.layoutIfNeeded()

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
        let closeRow = rows(in: overlay)[1]

        type("close", into: overlay)

        XCTAssertEqual(rows(in: overlay).count, 1)
        XCTAssertTrue(rows(in: overlay)[0] === closeRow, "the surviving command keeps its row view")
    }

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

    func test_repoPicker_branchAppearsWhenTheBackgroundProbeLands() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-picker-\(UUID().uuidString)", isDirectory: true)
        let gitDir = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/zen-450\n".utf8)
            .write(to: gitDir.appendingPathComponent("HEAD"))
        defer { try? FileManager.default.removeItem(at: repo) }

        let overlay = makeRepoPicker(entries: [workspace("repo", path: repo)])
        mount(overlay)
        let labels = descendants(of: rows(in: overlay)[1]).compactMap { $0 as? NSTextField }
        let branch = labels.first { $0.stringValue != "repo" }
        XCTAssertEqual(branch?.stringValue, "", "nothing has probed the folder yet")

        waitUntil(branch?.stringValue == "feature/zen-450", "the branch to land when the probe does")
    }

    func test_repoPicker_filterNarrowsWorkspacesKeepingAddRowPinned() throws {
        var chosen: (Workspace, Bool)?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")], onChoose: { chosen = ($0, $1) })
        mount(overlay)
        type("bet", into: overlay)
        XCTAssertEqual(overlay.numberOfRows(), 2)
        try sendReturn(to: overlay)
        XCTAssertEqual(chosen?.0.title, "beta")
        XCTAssertEqual(chosen?.1, false)
    }
}
