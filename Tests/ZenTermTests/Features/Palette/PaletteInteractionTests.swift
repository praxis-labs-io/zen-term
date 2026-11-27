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
            PaletteCommand(title: "Split Vertically", shortcut: "⌘D", category: .panes, chord: .splitVertical),
            PaletteCommand(title: "Close Pane", shortcut: "⌘W", category: .panes, chord: .closePane),
            PaletteCommand(title: "New Tab", shortcut: "⌘T", category: .tabs, chord: .newTab),
        ]
        return CommandPaletteOverlay(
            commands: { commands },
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

    func test_commandPalette_thePointerMovesTheCursor_andTheArrowContinuesFromIt() throws {
        Motion.isReduceMotionEnabled = { true }
        var ran: KeyInterceptor.ReservedChord?
        let overlay = makeCommandPalette(onRun: { ran = $0 })
        let window = mount(overlay)
        window.layoutIfNeeded()
        let cursor = Theme.current.chrome.fill(.active).cgColor
        let shown = rows(in: overlay)
        XCTAssertEqual(shown.map { $0.layer?.backgroundColor == cursor }, [true, false, false])

        let enter = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        shown[2].mouseEntered(with: enter)
        XCTAssertEqual(
            shown.map { $0.layer?.backgroundColor == cursor }, [false, false, true],
            "the pointer's row is not the one lit row")

        send(Self.moveUp, to: overlay)
        XCTAssertEqual(
            shown.map { $0.layer?.backgroundColor == cursor }, [false, true, false],
            "the arrow does not continue from the pointer's row")
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .closePane)
    }

    private func mountForSliding() -> (CommandPaletteOverlay, [SelectableRowView], RowFillSlide) {
        Motion.isReduceMotionEnabled = { false }
        let overlay = makeCommandPalette()
        mount(overlay).layoutIfNeeded()
        return (overlay, rows(in: overlay), overlay.fillSlideForTesting)
    }

    func test_commandPalette_theArrowSlidesTheCursorsFill_overTheHeader() {
        let (overlay, shown, slide) = mountForSliding()
        XCTAssertFalse(slide.isSlidingForTesting(.highlight), "the first cursor appears in place")
        XCTAssertGreaterThan(shown[0].layer?.backgroundColor?.alpha ?? 0, 0)

        send(Self.moveDown, to: overlay)
        send(Self.moveDown, to: overlay)

        XCTAssertTrue(slide.isSlidingForTesting(.highlight))
        XCTAssertIdentical(slide.slidingRowForTesting(.highlight), shown[2], "a second press carries the slide on")
        XCTAssertEqual(slide.slideFrameForTesting(.highlight), slide.frameForTesting(of: shown[2]))
        XCTAssertEqual(shown[2].layer?.backgroundColor?.alpha, 0, "the slide stands in for the row's fill")
        XCTAssertEqual(shown[0].layer?.backgroundColor?.alpha, 0)
        waitUntil(slide.slidingRowForTesting(.highlight) == nil, "the slide to land")
        XCTAssertEqual(shown[2].layer?.backgroundColor, shown[2].restingFill.cgColor)
        XCTAssertGreaterThan(shown[2].layer?.backgroundColor?.alpha ?? 0, 0)
    }

    func test_commandPalette_thePointerSlidesTheCursorsFill() throws {
        let (overlay, shown, slide) = mountForSliding()
        let window = try XCTUnwrap(overlay.window)

        shown[1].mouseEntered(
            with: try XCTUnwrap(
                NSEvent.enterExitEvent(
                    with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                    userData: nil)))

        XCTAssertTrue(slide.isSlidingForTesting(.highlight))
        XCTAssertIdentical(slide.slidingRowForTesting(.highlight), shown[1])
    }

    func test_commandPalette_aQueryRebuildsTheRows_andTheCursorsFillAppearsInPlace() {
        let (overlay, _, slide) = mountForSliding()
        send(Self.moveDown, to: overlay)
        XCTAssertTrue(slide.isSlidingForTesting(.highlight), "precondition")

        type("tab", into: overlay)
        overlay.layoutSubtreeIfNeeded()

        XCTAssertFalse(slide.isSlidingForTesting(.highlight), "no slide from a row the rebuild dropped or moved")
        XCTAssertNil(slide.slidingRowForTesting(.highlight))
        let lit = rows(in: overlay).filter { $0.isHighlighted }
        XCTAssertEqual(lit.count, 1)
        XCTAssertEqual(lit.first?.layer?.backgroundColor, lit.first?.restingFill.cgColor)
        XCTAssertGreaterThan(lit.first?.layer?.backgroundColor?.alpha ?? 0, 0)
    }

    func test_commandPalette_reduceMotion_snapsTheCursorsFill() {
        let (overlay, shown, slide) = mountForSliding()
        Motion.isReduceMotionEnabled = { true }

        send(Self.moveDown, to: overlay)

        XCTAssertFalse(slide.isSlidingForTesting(.highlight))
        XCTAssertEqual(shown[1].layer?.backgroundColor, shown[1].restingFill.cgColor)
        XCTAssertGreaterThan(shown[1].layer?.backgroundColor?.alpha ?? 0, 0)
        XCTAssertEqual(shown[0].layer?.backgroundColor?.alpha, 0)
    }

    func test_commandPalette_theArrowStopsAtTheEnds() {
        var ran: [KeyInterceptor.ReservedChord] = []
        let overlay = makeCommandPalette(onRun: { ran.append($0) })
        mount(overlay)

        send(Self.moveUp, to: overlay)
        send(Self.insertNewline, to: overlay)
        for _ in 0..<4 { send(Self.moveDown, to: overlay) }
        send(Self.insertNewline, to: overlay)

        XCTAssertEqual(ran, [.splitVertical, .newTab])
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

    private func catalogPalette() -> CommandPaletteOverlay {
        CommandPaletteOverlay(
            commands: { CommandCatalog.commands(tabCount: 3, workspaceCount: 1) }, onRun: { _ in }, onDismiss: {})
    }

    private func details(in overlay: PaletteOverlay) -> [String: String] {
        Dictionary(
            rows(in: overlay).map { ($0.title, $0.detailLabel.isHidden ? "" : $0.detail) },
            uniquingKeysWith: { first, _ in first })
    }

    func test_commandPalette_filtering_namesEachRowsCategory() {
        let overlay = catalogPalette()
        let window = mount(overlay)
        window.layoutIfNeeded()
        type("close", into: overlay)

        let shown = details(in: overlay)
        XCTAssertEqual(shown["Close Tab"], "Tabs")
        XCTAssertEqual(shown["Close Pane"], "Panes")
        XCTAssertFalse(overlay.rowViews.contains { $0 is PaletteSectionHeader }, "a filtered list has no headers")
    }

    func test_commandPalette_emptyQuery_groupsUnderHeadersWithNoDetail() {
        let overlay = catalogPalette()
        let window = mount(overlay)
        window.layoutIfNeeded()
        type("close", into: overlay)
        type("", into: overlay)

        XCTAssertTrue(overlay.rowViews.contains { $0 is PaletteSectionHeader })
        XCTAssertEqual(Set(details(in: overlay).values), [""], "a header already names the category")
    }

    func test_commandPalette_everyRowLeadsWithItsCommandsChip() {
        let overlay = catalogPalette()
        mount(overlay)
        let commands = CommandCatalog.commands(tabCount: 3, workspaceCount: 1)
        let shown = rows(in: overlay)
        XCTAssertEqual(shown.count, commands.count)
        for (row, command) in zip(shown, commands) {
            XCTAssertEqual(row.title, command.title)
            XCTAssertEqual(row.content.leading, .process(command.icon), command.title)
        }
    }

    func test_commandPalette_aToolFloatsChipDrawsItsConfiguredIcon() throws {
        let overlay = catalogPalette()
        let window = mount(overlay)
        window.layoutIfNeeded()
        let scratch = try XCTUnwrap(rows(in: overlay).first { $0.title == ToolFloat.scratch.title })
        let chip = try XCTUnwrap(scratch.processBadgeForTesting, "a float row leads with a chip")

        XCTAssertEqual(chip.process?.mark, ToolFloat.scratch.icon)
        XCTAssertNotNil(chip.iconImageForTesting, "the chip draws nothing for the float's icon")
        type("scratch", into: overlay)
        XCTAssertEqual(scratch.detail, CommandCategory.tools.title)
    }

    func test_commandPalette_scrollModeAndFindRowsWearTheirOwnChips() throws {
        let overlay = catalogPalette()
        let window = mount(overlay)
        window.layoutIfNeeded()
        let shown = rows(in: overlay)
        for (title, icon) in [("Scroll Mode", ProcessIcon.scrollMode), ("Find in Scrollback", .find)] {
            let row = try XCTUnwrap(shown.first { $0.title == title }, title)
            let chip = try XCTUnwrap(row.processBadgeForTesting, title)
            XCTAssertEqual(chip.process, icon, title)
            XCTAssertNotNil(chip.iconImageForTesting, "\(title)'s mark \(icon.mark) is not in the bundle")
        }
    }

    func test_commandPalette_everyChipTakesItsGroupsPurposeTint() throws {
        let overlay = catalogPalette()
        let window = mount(overlay)
        window.layoutIfNeeded()
        let hues: [CommandCategory: AccentSlot] = [
            .workspaces: .magenta, .tabs: .cyan, .panes: .yellow, .terminal: .green, .window: .blue, .tools: .green,
        ]
        let commands = CommandCatalog.commands(tabCount: 3, workspaceCount: 1)
        let shown = rows(in: overlay)
        XCTAssertEqual(shown.count, commands.count)
        for (row, command) in zip(shown, commands) {
            let chip = try XCTUnwrap(row.processBadgeForTesting, command.title)
            let expected =
                hues[command.category].map { $0.color(in: Theme.current.terminal).nsColor }
                ?? Theme.current.chrome.ink(.normal)
            XCTAssertEqual(chip.iconTintForTesting, expected, "\(command.title) in \(command.category.title)")
        }
    }

    func test_commandPalette_everyHeaderButTheFirst_leavesAGapAboveIt() {
        let overlay = catalogPalette()
        let window = mount(overlay)
        type("close", into: overlay)
        type("", into: overlay)
        window.layoutIfNeeded()

        let headers = overlay.rowViews.enumerated().filter { $0.element is PaletteSectionHeader }
        XCTAssertGreaterThan(headers.count, 1)
        for (index, header) in headers {
            let gap = index == 0 ? 0 : PaletteSectionHeader.sectionGap
            XCTAssertEqual(header.frame.height, PaletteSectionHeader.height + gap, accuracy: 0.5, "header at \(index)")
        }
    }

    func test_aToolFloatWhoseIconDrawsNothing_fallsBackToTheToolsChip() {
        let typo = ToolFloat(
            id: "typo", order: 1, title: "Typo", icon: "hammer.fil", command: "", dir: nil, widthFraction: 0.5,
            heightFraction: 0.5, requiresGitRepo: false, persist: .ephemeral, toggle: Chord(command: true, key: "y"))
        XCTAssertNil(ProcessIcon.toolFloat(typo))
        XCTAssertNotNil(ProcessIcon.toolFloat(.scratch))
        let command = PaletteCommand(
            title: typo.title, shortcut: "", category: .tools, chord: .toggleToolFloat(typo.id),
            ownIcon: ProcessIcon.toolFloat(typo))
        XCTAssertEqual(command.icon, CommandCategory.tools.icon)
    }

    func test_commandCategory_everyChipsMarkIsBundled() {
        for category in CommandCategory.allCases {
            XCTAssertNotNil(
                category.icon.image, "\(category.title)'s mark \(category.icon.mark) is not in the bundle")
        }
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
            PaletteCommand(title: "Open Settings", shortcut: "⌘,", category: .app, chord: .openSettings),
            PaletteCommand(
                title: "Write Screen to File and Open", shortcut: "", category: .terminal, chord: .openScreenFile),
        ]
        let overlay = CommandPaletteOverlay(
            commands: { commands },
            onRun: { ran = $0 }, onDismiss: {})
        mount(overlay)
        type("ap", into: overlay)
        XCTAssertEqual(overlay.numberOfRows(), 2, "Write Screen to File and Open by title, Open Settings by category")
        send(Self.insertNewline, to: overlay)
        XCTAssertEqual(ran, .openScreenFile)
    }

    private func makeLongCommandPalette() -> CommandPaletteOverlay {
        let commands =
            (0..<12).map {
                PaletteCommand(
                    title: "Pane action \($0)", shortcut: "⌘\($0)", category: .panes, chord: .splitVertical)
            }
            + (0..<12).map {
                PaletteCommand(
                    title: "Tab action \($0)", shortcut: "⌥\($0)", category: .tabs, chord: .newTab)
            }
        return CommandPaletteOverlay(
            commands: { commands },
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

    private func pressesUntilTheListScrolls() throws -> Int {
        Motion.isReduceMotionEnabled = { true }
        let (overlay, scroll) = try mountLongPalette()
        var presses = 0
        while scroll.contentView.bounds.minY < 0.5, presses < overlay.rowViews.count {
            send(Self.moveDown, to: overlay)
            presses += 1
        }
        XCTAssertGreaterThan(
            scroll.contentView.bounds.minY, 0.5, "the list has to scroll for this test to mean anything")
        return presses
    }

    private func mountOneRowShortOfScrolling() throws -> (CommandPaletteOverlay, NSScrollView, RowFillSlide) {
        let presses = try pressesUntilTheListScrolls()
        let (overlay, scroll) = try mountLongPalette()
        for _ in 0..<(presses - 1) { send(Self.moveDown, to: overlay) }
        Motion.isReduceMotionEnabled = { false }
        return (overlay, scroll, overlay.fillSlideForTesting)
    }

    private func selectedRow(of overlay: PaletteOverlay) throws -> ListRow {
        try XCTUnwrap(overlay.rowViews.first { $0.isSelected } as? ListRow)
    }

    func test_commandPalette_arrowingPastTheMargin_carriesTheSlideWithTheScroll() throws {
        let (overlay, scroll, slide) = try mountOneRowShortOfScrolling()
        let leaving = slide.frameForTesting(of: try selectedRow(of: overlay))
        let top = scroll.contentView.bounds.minY

        send(Self.moveDown, to: overlay)

        let scrolled = scroll.contentView.bounds.minY - top
        XCTAssertGreaterThan(scrolled, 0)
        let arriving = try selectedRow(of: overlay)
        XCTAssertIdentical(slide.slidingRowForTesting(.highlight), arriving)
        XCTAssertEqual(
            slide.slideStartForTesting(.highlight), leaving.offsetBy(dx: 0, dy: scrolled),
            "the fill starts where the last row showed on screen, not where the scroll carried it")
        XCTAssertEqual(slide.slideFrameForTesting(.highlight), slide.frameForTesting(of: arriving))
        waitUntil(slide.slidingRowForTesting(.highlight) == nil, "the slide to land")
        XCTAssertEqual(arriving.layer?.backgroundColor, arriving.restingFill.cgColor)
    }

    func test_commandPalette_reversingMidSlide_retargetsFromWhereTheFillIs() throws {
        let (overlay, _, slide) = try mountOneRowShortOfScrolling()
        let leaving = try selectedRow(of: overlay)
        send(Self.moveDown, to: overlay)
        let inFlight = try XCTUnwrap(slide.slideStartForTesting(.highlight))

        send(Self.moveUp, to: overlay)

        XCTAssertIdentical(slide.slidingRowForTesting(.highlight), leaving)
        XCTAssertEqual(slide.slideStartForTesting(.highlight), inFlight)
        XCTAssertEqual(slide.slideFrameForTesting(.highlight), slide.frameForTesting(of: leaving))
    }

    func test_commandPalette_arrowingPastTheMarginUnderReduceMotion_snapsTheFill() throws {
        let (overlay, scroll, slide) = try mountOneRowShortOfScrolling()
        Motion.isReduceMotionEnabled = { true }
        let top = scroll.contentView.bounds.minY

        send(Self.moveDown, to: overlay)

        XCTAssertGreaterThan(scroll.contentView.bounds.minY, top)
        XCTAssertFalse(slide.isSlidingForTesting(.highlight))
        let arriving = try selectedRow(of: overlay)
        XCTAssertEqual(arriving.layer?.backgroundColor, arriving.restingFill.cgColor)
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
            title: title, path: path, tabs: [], env: [:])
    }

    private func makeRepoPicker(
        entries: [Workspace],
        onChoose: @escaping (Workspace, WorktreeOrigin?) -> Void = { _, _ in },
        onAddWorkspace: @escaping () -> Void = {},
        onNewWorkspace: @escaping (String?) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) -> RepoPickerOverlay {
        RepoPickerOverlay(
            entries: entries,
            onChoose: onChoose, onAddWorkspace: onAddWorkspace, onNewWorkspace: onNewWorkspace,
            onDismiss: onDismiss)
    }

    func test_repoPicker_returnOnAnEmptyQuery_opensTheFirstWorkspace_ratherThanMakingOne() throws {
        var chosen: Workspace?
        var addOpened = false
        var made = false
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")],
            onChoose: { ws, _ in chosen = ws }, onAddWorkspace: { addOpened = true },
            onNewWorkspace: { _ in made = true })
        mount(overlay)
        try sendReturn(to: overlay)
        XCTAssertEqual(chosen?.title, "alpha")
        XCTAssertFalse(made, "an empty query lists no New Workspace row")
        XCTAssertFalse(addOpened)
    }

    func test_repoPicker_returnOnAQueryThatMatchesNothing_stillMakesAWorkspace() throws {
        var chosen: Workspace?
        var made = false
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")],
            onChoose: { ws, _ in chosen = ws }, onNewWorkspace: { _ in made = true })
        mount(overlay)
        type("zzzz", into: overlay)
        try sendReturn(to: overlay)
        XCTAssertTrue(made)
        XCTAssertNil(chosen)
    }

    func test_repoPicker_shiftEnterOpensLikeEnter() throws {
        var chosen: [Workspace] = []
        let overlay = makeRepoPicker(entries: [workspace("alpha")], onChoose: { ws, _ in chosen.append(ws) })
        mount(overlay)
        try sendReturn(to: overlay, modifiers: .shift)
        XCTAssertEqual(chosen.map(\.title), ["alpha"], "⇧↵ no longer replaces a tab")
    }

    func test_repoPicker_downArrowReachesAddRowAndActivatesIt() throws {
        var chosen: Workspace?
        var addOpened = false
        let overlay = makeRepoPicker(
            entries: [workspace("alpha")],
            onChoose: { ws, _ in chosen = ws }, onAddWorkspace: { addOpened = true })
        mount(overlay)
        send(Self.moveDown, to: overlay)
        try sendReturn(to: overlay)
        XCTAssertTrue(addOpened)
        XCTAssertNil(chosen)
    }

    func test_repoPicker_reusedRows_keepTheirViewsAndFollowTheFilterOrder() {
        let overlay = makeRepoPicker(entries: [workspace("zeta"), workspace("alpha")])
        mount(overlay)
        let (zetaRow, alphaRow, addRow) = (rows(in: overlay)[0], rows(in: overlay)[1], rows(in: overlay)[2])

        type("a", into: overlay)

        let arranged = rowsStack(in: overlay).arrangedSubviews
        XCTAssertEqual(
            Array(arranged.dropFirst()), [alphaRow, zetaRow, addRow],
            "every listed row is reused, re-ordered by the filter rather than rebuilt")
        XCTAssertEqual((arranged.first as? RepoPickerOverlay.ActionRowView)?.title, "New Workspace “a”")
    }

    func test_repoPicker_clickingAReusedRow_runsWhereItNowSits() {
        var chosen: Workspace?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")], onChoose: { ws, _ in chosen = ws })
        let window = mount(overlay)
        window.layoutIfNeeded()
        let betaRow = rows(in: overlay)[1]

        type("bet", into: overlay)
        window.layoutIfNeeded()

        XCTAssertTrue(rows(in: overlay).contains { $0 === betaRow }, "beta's row must be the reused one")
        click(betaRow)
        XCTAssertEqual(chosen?.title, "beta", "a reused row runs its current index, not the one it was built at")
    }

    func test_commandPalette_commandsSharingATitle_keepTheirOwnShortcut() {
        var ran: KeyInterceptor.ReservedChord?
        let shortcuts: [KeyInterceptor.ReservedChord: String] = [.newTab: "⌘T", .toggleToolFloat("nt"): "⌘⇧J"]
        let overlay = CommandPaletteOverlay(
            commands: {
                [
                    PaletteCommand(title: "New Tab", shortcut: "⌘T", category: .tabs, chord: .newTab),
                    PaletteCommand(
                        title: "New Tab", shortcut: "⌘⇧J", category: .tools,
                        chord: .toggleToolFloat("nt")),
                ]
            },
            onRun: { ran = $0 }, onDismiss: {})
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

        overlay.reapplyThemeTree()

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
        let row = rows(in: overlay)[0]
        func showsBranch() -> Bool {
            descendants(of: row).contains { ($0 as? NSTextField)?.stringValue == "feature/zen-450" }
        }
        XCTAssertFalse(showsBranch(), "nothing has probed the folder yet")

        waitUntil(showsBranch(), "the branch to land when the probe does")
    }

    func test_repoPicker_filterNarrowsWorkspacesKeepingAddRowPinned() throws {
        var chosen: Workspace?
        let overlay = makeRepoPicker(
            entries: [workspace("alpha"), workspace("beta")], onChoose: { ws, _ in chosen = ws })
        mount(overlay)
        type("bet", into: overlay)
        XCTAssertEqual(overlay.numberOfRows(), 3, "New Workspace, the one match and Add")
        try sendReturn(to: overlay)
        XCTAssertEqual(chosen?.title, "beta", "a query that matches takes the selection off New Workspace")
    }
}
