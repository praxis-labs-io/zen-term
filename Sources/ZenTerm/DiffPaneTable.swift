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

    /// Move the current line to the next / previous hunk header and bring it to the top — the fast
    /// jump through a long file (⌘j / ⌘k), so you don't hold the arrow from line 1 to line 200.
    func jumpToNextHunk() { jumpHunk(1) }
    func jumpToPrevHunk() { jumpHunk(-1) }

    private func jumpHunk(_ direction: Int) {
        let rows = source.rows
        guard !rows.isEmpty else { return }
        let start = table.selectedRow >= 0 ? table.selectedRow : (direction > 0 ? -1 : rows.count)
        var index = start + direction
        while index >= 0, index < rows.count {
            if case .hunkHeader = rows[index] {
                table.selectRowIndexes([index], byExtendingSelection: false)
                scrollRowToTop(index)
                return
            }
            index += direction
        }
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
