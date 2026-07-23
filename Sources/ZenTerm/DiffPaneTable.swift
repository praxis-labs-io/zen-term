import AppKit

/// The right pane's diff, rendered as a virtualized `NSTableView`: fixed-height monospace rows, only
/// the visible ones built and reused. It's layout-agnostic — it renders whatever `DiffRow`s it's given
/// (side-by-side or inline), picking `DiffLineCell` or `UnifiedLineCell` per row — so switching layout
/// is just a re-`show`. Switching files is a whole-table `reloadData`, so arrowing quickly through the
/// tree stays cheap no matter the file's size. A current-line highlight moves with the arrow keys;
/// ⌘j/⌘k jump between changes (driven from the overlay).
final class DiffPaneTable: NSView {
    private let table = DiffTableView()
    private let scroll = NSScrollView()
    private let source = Source()

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
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowHeight = DiffCellMetrics.rowHeight
        table.usesAutomaticRowHeights = false
        table.dataSource = source
        table.delegate = source
        table.onHorizontalScroll = { [weak self] deltaX in self?.panHorizontally(by: deltaX) }
        table.onHorizontalStep = { [weak self] direction in self?.panByKey(direction) }
        table.onHalfPage = { [weak self] direction in self?.halfPage(direction) }
        table.onSelectionMoved = { [weak self] in self?.centerSelectedRow() }

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
    /// The live content width the fold policy keys off — for a resize-driven interaction test.
    var contentWidthForTesting: CGFloat { table.bounds.width }

    func show(_ rows: [DiffRow]) {
        source.rows = rows
        isUnifiedLayout = rows.contains { if case .unified = $0 { return true } else { return false } }
        source.gutterWidth = DiffCellMetrics.gutterWidth(forDigits: Self.maxLineNumberDigits(in: rows))
        maxContentWidth = Self.widestLine(in: rows)
        horizontalOffset = 0
        source.offset = 0
        table.reloadData()
        // Always start with a current line so its highlight (a quiet outline while the tree holds focus)
        // is there to see immediately — the diff can be paged from the tree before it's ever focused.
        // Land it on the first real line, not the leading hunk header, so the pill reads as a line.
        if let firstLine = rows.firstIndex(where: { if case .hunkHeader = $0 { return false } else { return true } }) {
            table.selectRowIndexes([firstLine], byExtendingSelection: false)
        }
        table.scrollRowToVisible(0)
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

    /// Ctrl-D / Ctrl-U (vim half-page): +1 down, -1 up, nil otherwise. Left un-reserved on purpose —
    /// Ctrl-D is terminal EOF, so it only means half-page while the viewer holds first responder, never
    /// leaking to the shell behind it. Match the reservable modifier set exactly so ⌘⌃D etc. don't hit.
    static func halfPageDirection(for event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .control else {
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
        let current = table.selectedRow >= 0 ? table.selectedRow : table.rows(in: table.visibleRect).location
        let target = min(max(0, current + direction * page), source.rows.count - 1)
        table.selectRowIndexes([target], byExtendingSelection: false)
        centerRow(target)
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
            case .unified(let text, _, _, _):
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
        table.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    /// Esc out of the pane — wired to close the viewer.
    var onEscape: (() -> Void)? {
        get { table.onEscape }
        set { table.onEscape = newValue }
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
        let selected = table.selectedRow
        let anchor = selected >= 0 && NSLocationInRange(selected, visible) ? selected : visible.location
        var index = anchor + direction
        while index >= 0, index < rows.count {
            if isChangeClusterStart(at: index, in: rows) {
                table.selectRowIndexes([index], byExtendingSelection: false)
                centerRow(index)
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
        case .unified(_, let kind, _, _): return kind == .added || kind == .removed
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

    /// Re-center after the current line moves by arrow key (fired from the table's Up/Down).
    func centerSelectedRow() {
        guard table.selectedRow >= 0 else { return }
        centerRow(table.selectedRow)
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
            case .unified(_, _, let old, let new):
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
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? DiffLineRowView {
                return reused
            }
            let view = DiffLineRowView()
            view.identifier = id
            return view
        }
    }
}

/// The diff table. Accepts first responder even when empty (so keystrokes never leak to the terminal
/// behind the card), and on focus-in selects the first visible line so there's always a current line
/// to see and move. Arrows move the line and scroll (default `NSTableView` behavior).
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
    /// Fired after Up/Down moved the current line, so the pane can re-center it.
    var onSelectionMoved: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

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
        if ok, selectedRow == -1, numberOfRows > 0 {
            let visible = rows(in: visibleRect)
            let target = visible.length > 0 ? visible.location : 0
            selectRowIndexes([target], byExtendingSelection: false)
            scrollRowToVisible(target)
        }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if let direction = DiffPaneTable.halfPageDirection(for: event) {
            onHalfPage?(direction)
            return
        }
        switch KeyboardFocus.key(for: event) {
        case .escape:
            // Claim Esc before the table's own cancelOperation (which would just clear selection).
            onEscape?()
        case .left:
            onHorizontalStep?(-1)
        case .right:
            onHorizontalStep?(1)
        case .up, .down:
            super.keyDown(with: event)  // moves the current line…
            onSelectionMoved?()  // …then the pane re-centers it
        default:
            super.keyDown(with: event)
        }
    }
}

/// A diff row's current-line highlight, mirroring the file tree's selection: a solid accent fill while
/// the diff pane holds focus (`isEmphasized`), and a quiet accent outline when it doesn't — so paging
/// the diff from the tree still shows where the cursor is, without claiming focus. Theme-only (ZEN-27);
/// no system selection color.
private final class DiffLineRowView: NSTableRowView {
    /// The current-line pill spans the content: the diff pane already carries a horizontal margin off its
    /// edges (`diffTable`'s inset), so the pill takes no *additional* horizontal inset — it aligns with
    /// the content rather than nesting a second gap inside it. Rounded corners keep it reading as a pill.
    private static let horizontalInset: CGFloat = 0
    private static let verticalInset: CGFloat = 1.5
    private static let cornerRadius: CGFloat = 3

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let accent = Theme.current.chrome.accent.nsColor
        let rect = bounds.insetBy(dx: Self.horizontalInset, dy: Self.verticalInset)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        if isEmphasized {
            accent.withAlphaComponent(0.16).setFill()
            path.fill()
        } else {
            accent.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
