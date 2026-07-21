import AppKit

/// The right pane's side-by-side diff, rendered as a virtualized `NSTableView`: fixed-height
/// monospace rows, only the visible ones built and reused. Switching files is a whole-table
/// `reloadData`, so arrowing quickly through the tree stays cheap no matter the file's size. A
/// current-line highlight (like a normal diff viewer) moves with the arrow keys; ⌘j/⌘k jump between
/// hunks (driven from the overlay).
final class DiffPaneTable: NSView {
    private let table = DiffTableView()
    private let scroll = NSScrollView()
    private let source = Source()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.focusRingType = .none  // no system-blue ring on focus-in (ZEN-27: chrome is theme-only)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowHeight = DiffLineCell.rowHeight
        table.usesAutomaticRowHeights = false
        table.dataSource = source
        table.delegate = source

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

    func show(_ rows: [SideBySideRow]) {
        source.rows = rows
        table.reloadData()
        table.scrollRowToVisible(0)
    }

    /// Recolor the visible cells after a live theme change — each cell reads `Theme.current` when
    /// (re)built, so a reload is enough.
    func reapplyTheme() {
        table.reloadData()
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
                scrollRowToTop(max(0, index - 2))  // a couple lines of context above the change
                return
            }
            index += direction
        }
    }

    /// A change line (a row with an added or removed cell) whose predecessor isn't itself a change —
    /// i.e. the first line of a contiguous edit, the thing worth stopping on.
    private func isChangeClusterStart(at index: Int, in rows: [SideBySideRow]) -> Bool {
        guard Self.isChangeLine(rows[index]) else { return false }
        return index == 0 || !Self.isChangeLine(rows[index - 1])
    }

    private static func isChangeLine(_ row: SideBySideRow) -> Bool {
        guard case .lines(let left, let right) = row else { return false }
        return left?.kind == .removed || right?.kind == .added
    }

    private func scrollRowToTop(_ row: Int) {
        let clip = scroll.contentView
        let target = CGFloat(row) * table.rowHeight
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, target), maxY)))
        scroll.reflectScrolledClipView(clip)
    }

    private final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [SideBySideRow] = []

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? DiffLineCell ?? DiffLineCell(id: id)
            cell.configure(rows[row])
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

    override var acceptsFirstResponder: Bool { true }

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
        // Claim Esc before the table's own cancelOperation (which would just clear selection), so it
        // closes the viewer.
        if KeyboardFocus.key(for: event) == .escape {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A diff row's current-line highlight: a full-width fill in the accent while the pane is focused
/// (`isEmphasized`), dimming to a faint ink when focus is elsewhere so the line stays findable
/// without shouting. Theme-only (ZEN-27); no system selection color.
private final class DiffLineRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let chrome = Theme.current.chrome
        let fill = isEmphasized ? chrome.accent.nsColor.withAlphaComponent(0.16) : chrome.ink(alpha: 0.06)
        fill.setFill()
        bounds.fill()
    }
}
