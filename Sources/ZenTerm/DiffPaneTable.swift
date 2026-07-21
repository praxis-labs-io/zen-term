import AppKit

/// The right pane's side-by-side diff, rendered as a virtualized `NSTableView`: fixed-height
/// monospace rows, only the visible ones built and reused. Switching files is a whole-table
/// `reloadData`, so arrowing quickly through the tree stays cheap no matter the file's size. The
/// pane is a Tab stop with a current-line highlight (like a normal diff viewer): arrows move the
/// highlighted line and scroll to follow it, and the highlight brightens while the pane is focused.
final class DiffPaneTable: NSView {
    private let table = DiffTableView()
    private let scroll = NSScrollView()
    private let source = Source()

    /// Tab / Shift-Tab out of the pane — wired by the overlay to move focus around the ring.
    var onExitForward: (() -> Void)? {
        get { table.onExitForward }
        set { table.onExitForward = newValue }
    }
    var onExitBackward: (() -> Void)? {
        get { table.onExitBackward }
        set { table.onExitBackward = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.focusRingType = .none  // no system-blue ring on Tab-in (ZEN-27: chrome is theme-only)
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

/// The diff table, which manages its own keyboard: `NSTableView` handles arrows/Tab inside its own
/// `keyDown` (so `nextKeyView`/`moveUp` overrides don't fire), so Tab out is handled here; arrows
/// fall through to move the selected line and scroll. On focus-in it selects the first visible line
/// so there's always a visible current line to see and move.
private final class DiffTableView: NSTableView {
    var onExitForward: (() -> Void)?
    var onExitBackward: (() -> Void)?

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
        if case .tab(let shift)? = KeyboardFocus.key(for: event) {
            (shift ? onExitBackward : onExitForward)?()
            return
        }
        super.keyDown(with: event)  // arrows move the selected line + autoscroll
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
