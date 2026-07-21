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

/// One diff row: either a full-width hunk header or a `old │ new` line pair with line-number
/// gutters. Laid out manually (no Auto Layout) so a table full of these stays cheap, and reused
/// across scroll positions. Colors read `Theme.current` at configure time, so a live theme swap
/// (a `reloadData`) recolors.
final class DiffLineCell: NSView {
    static let rowHeight: CGFloat = 17
    private static let gutterWidth: CGFloat = 44
    private static let gutterGap: CGFloat = 6

    private let leftGutter = DiffLineCell.label(align: .right)
    private let leftText = DiffLineCell.label(align: .left)
    private let rule = NSView()
    private let rightGutter = DiffLineCell.label(align: .right)
    private let rightText = DiffLineCell.label(align: .left)
    private let headerLabel = DiffLineCell.label(align: .left)
    private var isHeader = false

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        wantsLayer = true
        rule.wantsLayer = true
        for view in [leftGutter, leftText, rule, rightGutter, rightText, headerLabel] { addSubview(view) }
    }

    convenience init() { self.init(id: NSUserInterfaceItemIdentifier("cell")) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func label(align: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.alignment = align
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = true
        label.drawsBackground = false
        return label
    }

    func configure(_ row: SideBySideRow) {
        let chrome = Theme.current.chrome
        switch row {
        case .hunkHeader(let text):
            isHeader = true
            headerLabel.isHidden = false
            headerLabel.stringValue = text
            headerLabel.textColor = chrome.accent.nsColor
            layer?.backgroundColor = chrome.ink(alpha: 0.04).cgColor
            for view in [leftGutter, leftText, rule, rightGutter, rightText] { view.isHidden = true }
        case .lines(let left, let right):
            isHeader = false
            headerLabel.isHidden = true
            rule.isHidden = false
            rule.layer?.backgroundColor = chrome.ink(alpha: 0.08).cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
            configureSide(gutter: leftGutter, text: leftText, cell: left, chrome: chrome)
            configureSide(gutter: rightGutter, text: rightText, cell: right, chrome: chrome)
        }
        needsLayout = true
    }

    private func configureSide(gutter: NSTextField, text: NSTextField, cell: DiffCell?, chrome: ChromeTheme) {
        gutter.isHidden = false
        text.isHidden = false
        gutter.textColor = chrome.muted.nsColor
        guard let cell else {
            gutter.stringValue = ""
            text.stringValue = ""
            text.drawsBackground = true
            text.backgroundColor = chrome.ink(alpha: 0.03)  // a filler: the absent side of this row
            return
        }
        gutter.stringValue = "\(cell.lineNumber)"
        text.stringValue = cell.text
        switch cell.kind {
        case .added:
            text.textColor = chrome.positive.nsColor
            text.drawsBackground = true
            text.backgroundColor = chrome.positive.nsColor.withAlphaComponent(0.14)
        case .removed:
            text.textColor = chrome.destructive.nsColor
            text.drawsBackground = true
            text.backgroundColor = chrome.destructive.nsColor.withAlphaComponent(0.14)
        case .context:
            text.textColor = chrome.foreground.nsColor
            text.drawsBackground = false
            text.backgroundColor = .clear
        }
    }

    override func layout() {
        super.layout()
        let gutter = Self.gutterWidth
        let height = bounds.height
        if isHeader {
            headerLabel.frame = NSRect(x: 8, y: 0, width: max(0, bounds.width - 8), height: height)
            return
        }
        let available = max(0, bounds.width - 2 * gutter - 1)
        let half = (available / 2).rounded(.down)
        leftGutter.frame = NSRect(x: 0, y: 0, width: gutter - Self.gutterGap, height: height)
        leftText.frame = NSRect(x: gutter, y: 0, width: half, height: height)
        rule.frame = NSRect(x: gutter + half, y: 0, width: 1, height: height)
        rightGutter.frame = NSRect(x: gutter + half + 1, y: 0, width: gutter - Self.gutterGap, height: height)
        rightText.frame = NSRect(x: 2 * gutter + half + 1, y: 0, width: available - half, height: height)
    }
}
