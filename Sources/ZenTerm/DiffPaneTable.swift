import AppKit

/// The right pane's side-by-side diff, rendered as a virtualized `NSTableView`: fixed-height
/// monospace rows, only the visible ones built and reused. Switching files is a whole-table
/// `reloadData`, so arrowing quickly through the tree stays cheap no matter the file's size (the
/// per-line-stack version rebuilt and re-laid-out every row on each keystroke). The pane is a Tab
/// stop that scrolls with the arrow keys once focused.
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
        table.selectionHighlightStyle = .none  // a diff pane scrolls; it doesn't select rows
        table.focusRingType = .none  // no system-blue ring on Tab-in (ZEN-27: chrome is theme-only)
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

    /// The view to make first responder so arrows scroll this pane.
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
    }
}

/// The diff table, which manages its own keyboard: `NSTableView` handles arrows/Tab inside its own
/// `keyDown` (so `nextKeyView`/`moveUp` overrides don't fire), so the exit keys and line scrolling
/// are handled here directly. Selection is off — this pane scrolls, it doesn't pick rows.
private final class DiffTableView: NSTableView {
    var onExitForward: (() -> Void)?
    var onExitBackward: (() -> Void)?

    /// Rows scrolled per arrow press — a few lines so held-key repeat moves at a readable pace.
    private static let scrollRows = 3

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .tab(let shift):
            (shift ? onExitBackward : onExitForward)?()
        case .up:
            scroll(rows: -Self.scrollRows)
        case .down:
            scroll(rows: Self.scrollRows)
        default:
            super.keyDown(with: event)
        }
    }

    private func scroll(rows: Int) {
        guard let clip = enclosingScrollView?.contentView else { return }
        var origin = clip.bounds.origin
        origin.y += CGFloat(rows) * rowHeight
        let maxY = max(0, frame.height - clip.bounds.height)  // the table is its own scroll document
        origin.y = min(max(0, origin.y), maxY)
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}
