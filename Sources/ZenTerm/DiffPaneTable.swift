import AppKit

/// The right pane's side-by-side diff, rendered as a virtualized `NSTableView`: fixed-height
/// monospace rows, only the visible ones built and reused. Switching files is a whole-table
/// `reloadData`, so arrowing quickly through the tree stays cheap no matter the file's size (the
/// per-line-stack version rebuilt and re-laid-out every row on each keystroke). Native vertical
/// scroll and keyboard focus come with the table — Tab into it, then arrows scroll.
final class DiffPaneTable: NSView {
    private let table = NSTableView()
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
        table.selectionHighlightStyle = .none  // a diff pane scrolls; it doesn't pick rows
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

    /// The view to make first responder so arrows/space scroll this pane.
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
