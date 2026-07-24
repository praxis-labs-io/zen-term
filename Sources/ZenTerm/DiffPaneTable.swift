import AppKit

/// The right pane's diff, rendered as a virtualized `NSTableView`: fixed-height monospace rows, only
/// the visible ones built and reused. It's layout-agnostic — it renders whatever `DiffRow`s it's given
/// (side-by-side or inline), picking `DiffLineCell` or `UnifiedLineCell` per row — so switching layout
/// is just a re-`show`. Switching files is a whole-table `reloadData`, so arrowing quickly through the
/// tree stays cheap no matter the file's size. A current-line highlight moves with the arrow keys;
/// ⌘j/⌘k jump between changes (driven from the overlay).
///
/// Selection is **linewise** (ZEN-227): `V` starts a visual selection anchored on the cursor, movement
/// extends it, and `y`/`Y` yank the selected code or a `path:line` reference. The cursor is tracked
/// explicitly rather than read back from `NSTableView.selectedRow`, which reports the *last* index in
/// the set — that's the anchor, not the cursor, whenever a selection was extended upward.
final class DiffPaneTable: NSView {
    private let table = DiffTableView()
    private let scroll = NSScrollView()
    private let source = Source()

    /// The row the cursor sits on. In a visual selection it's the moving end; otherwise it is the
    /// whole selection. -1 when there are no rows.
    private var cursorRow = -1
    /// The fixed end of a linewise visual selection, or nil when no selection is being extended.
    private var anchorRow: Int?

    /// How far through the post-yank flash we are (1 = full, 0 = gone). Vim's `on_yank` pulse: the
    /// yank leaves nothing on screen otherwise, so a copy that silently didn't take looks identical
    /// to one that did.
    private var flashLevel: CGFloat = 0
    private var flashedRows = IndexSet()
    private var flashTimer: Timer?
    private static let flashDuration: TimeInterval = 0.22
    private static let flashFrame: TimeInterval = 1.0 / 60

    /// Yank the current selection: `true` copies a `path:line` reference, `false` the code text.
    /// The pane holds the rows but not the file's path, so the overlay composes the string.
    var onYank: ((Bool) -> Void)?
    /// Esc with nothing to clear — wired to close the viewer. A visual selection is collapsed first.
    var onEscape: (() -> Void)?

    /// The shared horizontal pan applied to every visible row's text column(s) (0 = left-aligned).
    private var horizontalOffset: CGFloat = 0
    /// The widest line in the current file, measured per file — sets the horizontal scroll range.
    private var maxContentWidth: CGFloat = 0
    /// Which layout the current rows use, so the pan range subtracts the right content-column width.
    private var isUnifiedLayout = false
    /// Slack past the widest line so its last characters aren't flush to the column edge.
    private static let trailingPad: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        // `.automatic` reserves horizontal row insets (a source-list-style margin), which pushes the diff
        // content off the pane edges — a gap from the tree divider on the left and the card edge on the
        // right. `.plain` removes it so rows span the full pane width (same trap ZEN-236 hit on the tree).
        table.style = .plain
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.focusRingType = .none  // no system-blue ring on focus-in (ZEN-27: chrome is theme-only)
        table.allowsMultipleSelection = true  // linewise selection: drag, shift-click, V (ZEN-227)
        table.allowsEmptySelection = true
        // The vim keys are plain letters, so AppKit's type-select would race them for every keystroke.
        table.allowsTypeSelect = false
        table.rowHeight = DiffCellMetrics.rowHeight
        table.usesAutomaticRowHeights = false
        table.dataSource = source
        table.delegate = source
        table.onHorizontalScroll = { [weak self] deltaX in self?.panHorizontally(by: deltaX) }
        table.onHorizontalStep = { [weak self] direction in self?.panByKey(direction) }
        table.onHalfPage = { [weak self] direction in self?.halfPage(direction) }
        table.onMoveCursor = { [weak self] delta, extend in self?.moveCursor(by: delta, extending: extend) }
        table.onVimKey = { [weak self] key in self?.handleVimKey(key) }
        table.onEscape = { [weak self] in self?.handleEscape() }
        table.onMouseSelectionChanged = { [weak self] in self?.syncCursorAfterMouseSelection() }
        source.decorate = { [weak self] rowView, row in self?.decorate(rowView, row: row) }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The view to make first responder so arrows move the current line and scroll the pane.
    var scrollFocusTarget: NSView { table }
    var rowCountForTesting: Int { source.rows.count }
    /// The rows currently rendered — the other half of resolving a selection (with `selectedRows`).
    var rows: [DiffRow] { source.rows }
    /// The live content width the fold policy keys off — for a resize-driven interaction test.
    var contentWidthForTesting: CGFloat { table.bounds.width }

    /// The rows the selection covers — what a yank or a comment acts on.
    var selectedRows: IndexSet { table.selectedRowIndexes }
    /// Whether a visual selection is being extended (so Esc has something to collapse).
    var hasVisualSelection: Bool { anchorRow != nil }
    /// The cursor's row, for asserting a motion actually moved it.
    var cursorRowForTesting: Int { cursorRow }
    /// Whether the post-yank flash is running, so a test can assert the confirmation is wired to a
    /// copy that actually landed (the timing and the color are the runbook's, not a test's).
    var isFlashingForTesting: Bool { flashLevel > 0 }
    var flashedRowsForTesting: IndexSet { flashedRows }
    /// Drive the mouse selection path the way a click or a ⌘-click does — `super.mouseDown` writes the
    /// table's selection and then the pane adopts it, which a synthesized click can't reach reliably.
    func selectRowsFromMouseForTesting(_ rows: IndexSet) {
        table.selectRowIndexes(rows, byExtendingSelection: false)
        syncCursorAfterMouseSelection()
    }

    /// The cursor's line numbers — a row identity the caller can hold across a rows swap the pane can't
    /// bridge itself. The reload path clears the pane (`show([])`) while the new file's highlight is
    /// parsed, so by the time its rows arrive the pane has no cursor left to carry (ZEN-233).
    var cursorLine: DiffSelection.LineNumbers? { DiffSelection.lineNumbers(at: cursorRow, in: source.rows) }

    /// Render `rows`. `preservingSelection` is for a re-render of the *same* file — a layout flip
    /// (⌘I) or a resize crossing the auto-fold band — where losing the cursor and any running
    /// selection is a real loss: you were mid-review, and the layout change wasn't about the
    /// selection. The row *indices* differ between layouts (side-by-side pairs +/− lines that inline
    /// lists separately), so the cursor is carried by its line numbers and re-found, never by index.
    ///
    /// `restoringCursor` puts a cursor back from the *caller's* memory of it, for a reload that rebuilt
    /// the same file's rows from changed content. Only the cursor: a visual selection was made over
    /// lines that have since moved, so it collapses rather than re-anchoring somewhere it wasn't drawn.
    func show(
        _ rows: [DiffRow], preservingSelection: Bool = false,
        restoringCursor: DiffSelection.LineNumbers? = nil
    ) {
        let carried =
            preservingSelection
            ? (
                cursor: cursorLine,
                anchor: anchorRow.flatMap { DiffSelection.lineNumbers(at: $0, in: source.rows) }
            )
            : (cursor: restoringCursor, anchor: nil)

        cancelFlash()
        table.disarmPendingKeys()
        source.rows = rows
        isUnifiedLayout = rows.contains { if case .unified = $0 { return true } else { return false } }
        source.gutterWidth = DiffCellMetrics.gutterWidth(forDigits: Self.maxLineNumberDigits(in: rows))
        maxContentWidth = Self.widestLine(in: rows)
        horizontalOffset = 0
        source.offset = 0
        anchorRow = nil
        cursorRow = -1
        table.reloadData()

        if let carriedCursor = carried.cursor, let row = DiffSelection.row(for: carriedCursor, in: rows) {
            anchorRow = carried.anchor.flatMap { DiffSelection.row(for: $0, in: rows) }
            setCursor(row)
            return
        }
        // A new file: start with a current line so its highlight (a quiet outline while the tree holds
        // focus) is there to see immediately — the diff can be paged from the tree before it's ever
        // focused. Land it on the first real line, not the leading hunk header, so the pill reads as a line.
        if let firstLine = rows.firstIndex(where: { if case .hunkHeader = $0 { return false } else { return true } }) {
            setCursor(firstLine, center: false)
        }
        table.scrollRowToVisible(0)
    }

    // MARK: linewise selection (ZEN-227)

    /// Move the cursor to `row`, extending the visual selection when one is active. The single funnel
    /// for every cursor move — arrows, vim keys, change jumps, half-pages — so the selection, the
    /// centering, and the row decoration can never drift apart.
    private func setCursor(_ row: Int, center: Bool = true) {
        let count = source.rows.count
        guard count > 0 else { return }
        cursorRow = min(max(0, row), count - 1)
        applySelection()
        if center { centerRow(cursorRow) }
    }

    /// Push the cursor (and the anchor, when extending) onto the table's own selection.
    private func applySelection() {
        guard cursorRow >= 0 else { return }
        let rows: IndexSet
        if let anchor = anchorRow, source.rows.indices.contains(anchor) {
            rows = IndexSet(min(anchor, cursorRow)...max(anchor, cursorRow))
        } else {
            rows = IndexSet(integer: cursorRow)
        }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        refreshDecoration()
    }

    /// Move the cursor by `delta` rows. `extending` starts a visual selection first (shift-arrow), so
    /// the mouse-free path to a multi-line selection doesn't require `V`.
    func moveCursor(by delta: Int, extending: Bool = false) {
        guard !source.rows.isEmpty else { return }
        if extending, anchorRow == nil { anchorRow = max(0, cursorRow) }
        setCursor((cursorRow < 0 ? 0 : cursorRow) + delta)
    }

    /// `V` — start a linewise visual selection anchored on the cursor, or collapse the one already
    /// running (pressing V twice leaves you where you started, as in vim).
    func toggleVisual() {
        guard !source.rows.isEmpty else { return }
        if anchorRow != nil {
            clearVisual()
        } else {
            anchorRow = max(0, cursorRow)
            applySelection()
        }
    }

    /// Collapse the selection back to the cursor line, leaving the cursor where it is.
    func clearVisual() {
        anchorRow = nil
        applySelection()
    }

    /// Esc: collapse a running selection first, and only close the viewer once there's nothing left
    /// to clear — the same two-stage Esc vim has.
    private func handleEscape() {
        if hasVisualSelection {
            clearVisual()
        } else {
            onEscape?()
        }
    }

    private func handleVimKey(_ key: VimKey) {
        switch key {
        case .down: moveCursor(by: 1)
        case .up: moveCursor(by: -1)
        case .visual: toggleVisual()
        case .pendingTop: break  // the table resolves `gg` before it ever forwards one
        case .top: setCursor(0)
        case .bottom: setCursor(source.rows.count - 1)
        case .prevChange: jumpToPrevChange()
        case .nextChange: jumpToNextChange()
        case .yankCode: onYank?(false)
        case .yankReference: onYank?(true)
        }
    }

    /// A drag, shift-click, or ⌘-click moved the selection behind our back: adopt it, so the next
    /// keystroke extends from where the mouse left off instead of snapping back to the old cursor.
    ///
    /// The adopted selection is normalized to a contiguous range. A ⌘-click can leave gaps, but this
    /// pane's model is one anchor and one cursor, so the very next motion would fill those gaps in
    /// anyway — filling them now means the block you see is the block you'll yank, instead of it
    /// quietly growing under the next keystroke.
    ///
    /// Which end is the cursor isn't always the bottom: a shift-click *above* the cursor extends
    /// upward, so the mouse landed on the selection's first row. AppKit anchors a shift-click on the
    /// previously selected row, so when the old cursor is still an endpoint, that endpoint is the
    /// anchor and the other one is where the mouse went.
    private func syncCursorAfterMouseSelection() {
        let selected = table.selectedRowIndexes
        guard let first = selected.first, let last = selected.last else {
            anchorRow = nil
            refreshDecoration()
            return
        }
        guard first != last else {
            cursorRow = last
            anchorRow = nil
            applySelection()
            return
        }
        if cursorRow == last {
            anchorRow = last
            cursorRow = first
        } else {
            anchorRow = first
            cursorRow = last
        }
        applySelection()
    }

    // MARK: yank flash

    /// Pulse the yanked rows and fade out, the way nvim's `on_yank` does. Called by the overlay after
    /// a yank actually reaches the pasteboard, so it confirms the copy rather than the keystroke.
    func flashYank() {
        cancelFlash()
        flashedRows = table.selectedRowIndexes
        guard !flashedRows.isEmpty else { return }
        flashLevel = 1
        refreshDecoration()
        guard !Motion.isReduceMotionEnabled() else {
            // No fade, but still a beat of highlight — the flash *is* the confirmation, so it can't
            // be dropped entirely, only made still.
            flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashDuration, repeats: false) {
                [weak self] _ in self?.cancelFlash()
            }
            return
        }
        let step = CGFloat(Self.flashFrame / Self.flashDuration)
        flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashFrame, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            self.flashLevel -= step
            if self.flashLevel <= 0 {
                self.cancelFlash()
            } else {
                self.refreshDecoration()
            }
        }
    }

    /// Drop the flash immediately — on a new one, on a re-render, and at the fade's end.
    private func cancelFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        guard flashLevel != 0 else { return }
        flashLevel = 0
        flashedRows = IndexSet()
        refreshDecoration()
    }

    /// The horizontal scroll range: how far the widest line overhangs its content column. 0 = nothing
    /// to pan. The content column differs by layout (two half-width columns vs. one full-width one).
    private var maxHorizontalOffset: CGFloat {
        let column =
            isUnifiedLayout
            ? UnifiedLineCell.columnWidth(forTotalWidth: table.bounds.width, gutterWidth: source.gutterWidth)
            : DiffLineCell.columnWidth(forTotalWidth: table.bounds.width, gutterWidth: source.gutterWidth)
        return max(0, maxContentWidth + Self.trailingPad - column)
    }

    private func panHorizontally(by deltaX: CGFloat) {
        // Swipe left (negative deltaX) reveals the tail on the right, so the offset grows.
        setHorizontalOffset(horizontalOffset - deltaX)
    }

    /// One Left/Right arrow press worth of pan (a handful of characters), so holding the key glides.
    private static let keyStep: CGFloat = 32
    private func panByKey(_ direction: Int) {
        setHorizontalOffset(horizontalOffset + CGFloat(direction) * Self.keyStep)
    }

    /// The modifiers a chord may claim. Everything else AppKit stamps on an event (`.function`,
    /// `.numericPad`) is noise that must be masked off before comparing (ZEN-145).
    static let reservableModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// The vim keys the diff pane claims while it holds first responder (ZEN-227). Nothing reaches a
    /// terminal from here, so plain letters are free — but ⌘/⌃/⌥ must fall through, or ⌘C and ⌃D
    /// would land here instead of their own handlers.
    enum VimKey: Equatable {
        case down, up  // j / k
        case visual  // V
        /// A bare `g`, which only means something paired: the table arms on the first and resolves the
        /// second to `.top`. `.top` is never decoded directly.
        case pendingTop
        case top, bottom  // gg / G
        case prevChange, nextChange  // { / }
        case yankCode, yankReference  // y / Y
    }

    /// Decode a `keyDown` into the vim key it types, or nil for anything the pane doesn't claim.
    ///
    /// The base key is the *lowercased* `charactersIgnoringModifiers` and the shifted-ness comes from
    /// the modifier flags, never from the character's case: Caps Lock also uppercases, so reading case
    /// alone would turn `j` into a dead key and make a single `g` jump to the bottom the moment Caps
    /// Lock was on. Braces are matched on the typed character first, so a layout that doesn't put them
    /// on shift-bracket still works.
    static func vimKey(for event: NSEvent) -> VimKey? {
        // Shift is read from the flags; the other three mean this is somebody else's chord.
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return nil }
        switch event.characters {
        case "{": return .prevChange
        case "}": return .nextChange
        default: break
        }
        let shift = event.modifierFlags.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("j", false): return .down
        case ("k", false): return .up
        case ("v", true): return .visual
        case ("g", false): return .pendingTop
        case ("g", true): return .bottom
        case ("y", false): return .yankCode
        case ("y", true): return .yankReference
        case ("[", true): return .prevChange
        case ("]", true): return .nextChange
        default: return nil
        }
    }

    /// Ctrl-D / Ctrl-U (vim half-page): +1 down, -1 up, nil otherwise. Left un-reserved on purpose —
    /// Ctrl-D is terminal EOF, so it only means half-page while the viewer holds first responder, never
    /// leaking to the shell behind it. Match the reservable modifier set exactly so ⌘⌃D etc. don't hit.
    static func halfPageDirection(for event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection(reservableModifiers) == .control else {
            return nil
        }
        switch event.keyCode {
        case 2: return 1  // D
        case 32: return -1  // U
        default: return nil
        }
    }

    /// Half-page scroll that carries the current-line highlight with it, so the cursor stays put on
    /// screen instead of sliding off. Driven from both panes (Ctrl-D/U) — when the tree holds focus the
    /// line isn't painted (the tree owns the focus indicator), but the selection still moves so it's
    /// where you left it when you step back into the diff.
    func halfPage(_ direction: Int) {
        guard !source.rows.isEmpty else { return }
        let visibleRows = max(1, Int(scroll.contentView.bounds.height / table.rowHeight))
        let page = max(1, visibleRows / 2)
        let current = cursorRow >= 0 ? cursorRow : table.rows(in: table.visibleRect).location
        setCursor(current + direction * page)
    }

    private func setHorizontalOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), maxHorizontalOffset)
        guard clamped != horizontalOffset else { return }
        horizontalOffset = clamped
        source.offset = clamped
        table.enumerateAvailableRowViews { rowView, _ in
            for case let cell as DiffPanningCell in rowView.subviews { cell.horizontalOffset = clamped }
        }
    }

    /// The widest line across both columns, for the horizontal scroll range (hunk headers don't pan).
    /// The font is monospaced, so a line's UTF-16 length is a faithful proxy for its width: scan by
    /// length (cheap) and lay out only the single longest line, rather than measuring every line's text
    /// on the main thread — the latter hitches when switching to a large file (ZEN-90).
    private static func widestLine(in rows: [DiffRow]) -> CGFloat {
        var longest = ""
        var longestLength = 0
        func consider(_ text: String) {
            let length = text.utf16.count
            if length > longestLength {
                longest = text
                longestLength = length
            }
        }
        for row in rows {
            switch row {
            case .hunkHeader: break
            case .split(let left, let right):
                if let left { consider(left.text) }
                if let right { consider(right.text) }
            case .unified(let text, _, _, _, _):
                consider(text)
            }
        }
        return longestLength == 0
            ? 0 : (longest as NSString).size(withAttributes: [.font: DiffCellMetrics.font]).width.rounded(.up)
    }

    override func layout() {
        super.layout()
        // The column width changed with the pane, so the scroll range did too — re-clamp the offset.
        setHorizontalOffset(horizontalOffset)
    }

    /// Recolor the visible cells after a live theme change — each cell reads `Theme.current` when
    /// (re)built, so a reload is enough.
    func reapplyTheme() {
        table.reloadData()
    }

    /// Redraw the current-line highlight — called when focus enters or leaves the pane, since the
    /// cursor line is only drawn while the pane is focused.
    func redrawSelection() {
        refreshDecoration()
    }

    /// Re-stamp every instantiated row with where it sits in the selected block and whether it holds
    /// the cursor, then redraw. Row views aren't rebuilt when the selection changes, so this can't
    /// ride on `rowViewForRow` alone — that path covers only rows scrolled into view afterwards.
    private func refreshDecoration() {
        table.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self, let view = rowView as? DiffLineRowView else {
                rowView.needsDisplay = true
                return
            }
            self.decorate(view, row: row)
        }
    }

    /// Tell one row view how to draw itself: its position in the contiguous selected block (so the
    /// block reads as one shape rather than a stack of pills) and whether it carries the cursor.
    private func decorate(_ rowView: DiffLineRowView, row: Int) {
        let selected = table.selectedRowIndexes
        rowView.blockPosition = Self.blockPosition(of: row, in: selected)
        rowView.isCursorRow = row == cursorRow && selected.count > 1
        rowView.flashLevel = flashedRows.contains(row) ? flashLevel : 0
        rowView.needsDisplay = true
    }

    /// Where `row` sits in the run of selected rows around it — the two neighbours are all it takes.
    static func blockPosition(of row: Int, in selected: IndexSet) -> DiffLineRowView.BlockPosition {
        switch (selected.contains(row - 1), selected.contains(row + 1)) {
        case (true, true): return .middle
        case (true, false): return .last
        case (false, true): return .first
        case (false, false): return .only
        }
    }

    /// Jump to the start of the next / previous change cluster — a contiguous run of +/− lines,
    /// separated from the next by context. This works *within* a single hunk (the common case: git
    /// folds nearby edits into one hunk), which hunk-to-hunk jumping did not. Anchored on the top
    /// *visible* row, not the selection, since the selection goes stale when you scroll by trackpad.
    func jumpToNextChange() { jumpChange(1) }
    func jumpToPrevChange() { jumpChange(-1) }

    private func jumpChange(_ direction: Int) {
        let rows = source.rows
        guard !rows.isEmpty else { return }
        // Anchor on the highlighted line when it's on screen (consecutive keyboard jumps advance from
        // the last landing, not from the scrolled viewport-top, which sits above it and would re-find
        // the same change); fall back to the viewport-top only after a trackpad scroll moved the
        // selection off screen.
        let visible = table.rows(in: table.visibleRect)
        let from = cursorRow >= 0 && NSLocationInRange(cursorRow, visible) ? cursorRow : visible.location
        var index = from + direction
        while index >= 0, index < rows.count {
            if isChangeClusterStart(at: index, in: rows) {
                setCursor(index)  // extends the selection when one is running, like `}` in vim's visual mode
                return
            }
            index += direction
        }
    }

    /// A change line (a row with an added or removed cell) whose predecessor isn't itself a change —
    /// i.e. the first line of a contiguous edit, the thing worth stopping on.
    private func isChangeClusterStart(at index: Int, in rows: [DiffRow]) -> Bool {
        guard Self.isChangeLine(rows[index]) else { return false }
        return index == 0 || !Self.isChangeLine(rows[index - 1])
    }

    private static func isChangeLine(_ row: DiffRow) -> Bool {
        switch row {
        case .hunkHeader: return false
        case .split(let left, let right): return left?.kind == .removed || right?.kind == .added
        case .unified(_, let kind, _, _, _): return kind == .added || kind == .removed
        }
    }

    /// Scroll so `row` sits vertically centered, clamped at the file's ends — the diff keeps the
    /// current line in the middle (like `scrolloff=999`) so there's always context above and below.
    func centerRow(_ row: Int) {
        let clip = scroll.contentView
        let targetY = table.rect(ofRow: row).midY - clip.bounds.height / 2
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, targetY), maxY)))
        scroll.reflectScrolledClipView(clip)
    }

    /// The widest line-number digit count across the file's rows — sizes the gutters so a short file
    /// doesn't reserve room for digits it never shows.
    private static func maxLineNumberDigits(in rows: [DiffRow]) -> Int {
        var maxNumber = 0
        for row in rows {
            switch row {
            case .hunkHeader: break
            case .split(let left, let right):
                maxNumber = max(maxNumber, left?.lineNumber ?? 0, right?.lineNumber ?? 0)
            case .unified(_, _, let old, let new, _):
                maxNumber = max(maxNumber, old ?? 0, new ?? 0)
            }
        }
        return max(1, String(maxNumber).count)
    }

    private final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [DiffRow] = []
        /// The current shared pan, so a row scrolled into view lands already aligned with its siblings.
        var offset: CGFloat = 0
        /// The gutter width for the current file, sized to its widest line number and applied to each cell.
        var gutterWidth: CGFloat = DiffCellMetrics.nominalGutterWidth
        /// Stamps a row view with its selection-block position and cursor flag, so a row scrolled into
        /// view mid-selection draws as part of the block instead of as a lone pill.
        var decorate: ((DiffLineRowView, Int) -> Void)?

        private static let splitID = NSUserInterfaceItemIdentifier("split-cell")
        private static let unifiedID = NSUserInterfaceItemIdentifier("unified-cell")

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            // Inline lines get `UnifiedLineCell`; headers and side-by-side pairs get `DiffLineCell`.
            let cell: DiffPanningCell
            if case .unified = rows[row] {
                let unified =
                    tableView.makeView(withIdentifier: Self.unifiedID, owner: self) as? UnifiedLineCell
                    ?? UnifiedLineCell(id: Self.unifiedID)
                unified.gutterWidth = gutterWidth
                unified.configure(rows[row])
                cell = unified
            } else {
                let split =
                    tableView.makeView(withIdentifier: Self.splitID, owner: self) as? DiffLineCell
                    ?? DiffLineCell(id: Self.splitID)
                split.gutterWidth = gutterWidth
                split.configure(rows[row])
                cell = split
            }
            cell.horizontalOffset = offset
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("diff-row")
            let view: DiffLineRowView
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? DiffLineRowView {
                view = reused
            } else {
                view = DiffLineRowView()
                view.identifier = id
            }
            decorate?(view, row)
            return view
        }
    }
}

/// The diff table. Accepts first responder even when empty (so keystrokes never leak to the terminal
/// behind the card), and on focus-in puts the cursor on the first visible line so there's always one
/// to see and move. It routes every key the pane owns outward rather than moving its own selection —
/// the pane tracks the cursor and the visual anchor, and the two would drift if both wrote.
private final class DiffTableView: NSTableView {
    var onEscape: (() -> Void)?
    /// A horizontal-dominant scroll pans the diff columns instead of the table (which scrolls only
    /// vertically). Reports the raw `scrollingDeltaX`; the pane turns it into a clamped offset.
    var onHorizontalScroll: ((CGFloat) -> Void)?
    /// A Left/Right arrow press: pan the columns one step (+1 right / -1 left). Plain arrows are free
    /// in the diff pane — Up/Down move the current line, Left/Right fold rows only in the tree.
    var onHorizontalStep: ((Int) -> Void)?
    /// Ctrl-D / Ctrl-U half-page scroll (+1 down / -1 up).
    var onHalfPage: ((Int) -> Void)?
    /// Move the cursor by ±1 row; `extend` (shift held) starts a visual selection first.
    var onMoveCursor: ((Int, Bool) -> Void)?
    /// One of the vim keys the pane claims (`DiffPaneTable.vimKey`).
    var onVimKey: ((DiffPaneTable.VimKey) -> Void)?
    /// The selection changed from a drag or a shift-click rather than from the pane's own write.
    var onMouseSelectionChanged: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// A bare `g` is waiting for its partner (`gg` jumps to the top). Any other key clears it — vim
    /// puts no timeout on this, so neither does the pane.
    private var sawG = false

    /// The axis a trackpad gesture committed to at its start, held for the whole gesture (incl.
    /// momentum) so a diagonal or jittery scroll can't flip mid-stream and drift the columns sideways.
    private var gesturePansHorizontally: Bool?

    override func scrollWheel(with event: NSEvent) {
        // Decide the axis once, at the gesture's start, from its initial dominant delta.
        if event.phase == .began {
            gesturePansHorizontally = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        // Fall back to per-event dominance for a legacy mouse wheel (no gesture phases).
        let horizontal =
            gesturePansHorizontally ?? (abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY))
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            gesturePansHorizontally = nil
        }
        if horizontal {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 16
            onHorizontalScroll?(step)
            return
        }
        super.scrollWheel(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        sawG = false  // a half-typed `gg` doesn't survive leaving and coming back
        if ok, selectedRow == -1, numberOfRows > 0 {
            let visible = rows(in: visibleRect)
            let target = visible.length > 0 ? visible.location : 0
            selectRowIndexes([target], byExtendingSelection: false)
            onMouseSelectionChanged?()  // adopt it as the cursor — the pane didn't write this one
            scrollRowToVisible(target)
        }
        return ok
    }

    /// A drag or shift-click landed. `super` has already written the selection; tell the pane so it
    /// adopts the new cursor instead of snapping back on the next keystroke.
    override func mouseDown(with event: NSEvent) {
        sawG = false  // reaching for the mouse abandons a half-typed `gg`
        super.mouseDown(with: event)
        onMouseSelectionChanged?()
    }

    /// Disarm a half-typed `gg` — called when the pane re-renders, so an armed `g` can't survive into
    /// a different file and turn the next single `g` into a jump.
    func disarmPendingKeys() { sawG = false }

    override func keyDown(with event: NSEvent) {
        if let direction = DiffPaneTable.halfPageDirection(for: event) {
            sawG = false
            onHalfPage?(direction)
            return
        }
        if let key = DiffPaneTable.vimKey(for: event) {
            // `gg` is the one two-key sequence: a bare `g` arms, the second fires, anything else disarms.
            if key == .pendingTop {
                sawG.toggle()
                if !sawG { onVimKey?(.top) }
                return
            }
            sawG = false
            onVimKey?(key)
            return
        }
        sawG = false
        switch KeyboardFocus.key(for: event) {
        case .escape:
            // Claim Esc before the table's own cancelOperation (which would just clear selection).
            onEscape?()
        case .left:
            onHorizontalStep?(-1)
        case .right:
            onHorizontalStep?(1)
        case .up, .down:
            // The pane owns the cursor, so never let `super` move the selection: shift-arrow would
            // extend by AppKit's rules (from *its* anchor) and desync the two.
            let extend = event.modifierFlags.intersection(DiffPaneTable.reservableModifiers) == .shift
            onMoveCursor?(KeyboardFocus.key(for: event) == .down ? 1 : -1, extend)
        default:
            super.keyDown(with: event)
        }
    }
}

/// A diff row's selection highlight, mirroring the file tree's: a solid accent fill while the diff pane
/// holds focus (`isEmphasized`), and a quiet accent outline when it doesn't — so paging the diff from
/// the tree still shows where the cursor is, without claiming focus. Theme-only (ZEN-27); no system
/// selection color.
///
/// A multi-row linewise selection has to read as one block, not a stack of pills (ZEN-227). Rather than
/// build a per-corner path, each row draws a pill that overhangs into its selected neighbours by the
/// corner radius and clips to its own bounds: the block's outer corners keep their curve, the interior
/// seams come out square, and the outline case falls out of the same trick (the overhung edges clip
/// away, leaving a continuous border around the block).
final class DiffLineRowView: NSTableRowView {
    /// Where this row sits in the run of selected rows around it. Stamped by `DiffPaneTable`.
    enum BlockPosition { case only, first, middle, last }

    var blockPosition: BlockPosition = .only
    /// Whether this row carries the cursor *inside* a multi-row selection — it takes a stronger fill so
    /// the moving end stays findable. False for a single-row selection, which is already just the cursor.
    var isCursorRow = false
    /// How far through the post-yank flash this row is (1 = full, 0 = none). Drawn over the selection
    /// fill, so it reads as the block pulsing rather than as a second highlight.
    var flashLevel: CGFloat = 0

    /// The selection pill spans the content: the diff pane already carries a horizontal margin off its
    /// edges (`diffTable`'s inset), so the pill takes no *additional* horizontal inset — it aligns with
    /// the content rather than nesting a second gap inside it. Rounded corners keep it reading as a pill.
    private static let horizontalInset: CGFloat = 0
    private static let verticalInset: CGFloat = 1.5
    private static let cornerRadius: CGFloat = 3

    /// The flash's peak fill, well above the resting selection so the pulse is unmistakable without
    /// washing the code out.
    private static let flashPeakAlpha: CGFloat = 0.5

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).setClip()  // the overhang below is for the neighbour, not for us

        let accent = Theme.current.chrome.accent.nsColor
        let path = NSBezierPath(
            roundedRect: pillRect(), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        if isEmphasized {
            accent.withAlphaComponent(isCursorRow ? 0.28 : 0.16).setFill()
            path.fill()
        } else {
            accent.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        // The yank pulse rides on top of whichever of the two the row just drew, so it reads the same
        // whether the pane holds focus or not.
        guard flashLevel > 0 else { return }
        accent.withAlphaComponent(Self.flashPeakAlpha * min(1, flashLevel)).setFill()
        path.fill()
    }

    /// The pill, grown past the row's own edge on whichever side continues into a selected neighbour —
    /// the clip above trims the overhang, which is what squares off the interior seams.
    private func pillRect() -> NSRect {
        var rect = bounds.insetBy(dx: Self.horizontalInset, dy: Self.verticalInset)
        let overhang = Self.cornerRadius + Self.verticalInset
        // The row is flipped (`isFlipped` is true for table rows), so minY is the row's top edge.
        let growsUp = blockPosition == .middle || blockPosition == .last
        let growsDown = blockPosition == .middle || blockPosition == .first
        if growsUp {
            rect.origin.y -= overhang
            rect.size.height += overhang
        }
        if growsDown {
            rect.size.height += overhang
        }
        return rect
    }
}
