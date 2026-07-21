import AppKit

/// The data source + delegate for the diff viewer's left file tree. Renders each row as a name
/// plus a themed `+n −m` stat, and reports the selected file back through `onSelect`. Row views are
/// reused (like the diff pane's cells) and read `Theme.current` at configure time, so a live theme
/// swap (`reloadData`) recolors.
final class DiffTreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let roots: [DiffOutlineItem]
    private let onSelect: (FileDiff) -> Void

    private static let rowID = NSUserInterfaceItemIdentifier("diff-tree-row")
    private static let selectionRowID = NSUserInterfaceItemIdentifier("diff-tree-selection")

    init(files: [FileDiff], onSelect: @escaping (FileDiff) -> Void) {
        self.roots = DiffOutlineItem.roots(from: files)
        self.onSelect = onSelect
    }

    /// The first file in tree order, or nil for an empty tree — the initial selection.
    var firstFile: DiffOutlineItem? {
        func firstLeaf(in items: [DiffOutlineItem]) -> DiffOutlineItem? {
            for item in items {
                if item.fileDiff != nil { return item }
                if let nested = firstLeaf(in: item.children) { return nested }
            }
            return nil
        }
        return firstLeaf(in: roots)
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DiffOutlineItem)?.isDirectory ?? false
    }

    private func children(of item: Any?) -> [DiffOutlineItem] {
        guard let item else { return roots }
        return (item as? DiffOutlineItem)?.children ?? []
    }

    // MARK: delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DiffOutlineItem else { return nil }
        let row =
            outlineView.makeView(withIdentifier: Self.rowID, owner: self) as? DiffTreeRowView
            ?? DiffTreeRowView(id: Self.rowID)
        row.configure(node)
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let reused = outlineView.makeView(withIdentifier: Self.selectionRowID, owner: self)
            as? ThemedSelectionRowView
        {
            return reused
        }
        let row = ThemedSelectionRowView()
        row.identifier = Self.selectionRowID
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outline = notification.object as? NSOutlineView,
            let item = outline.item(atRow: outline.selectedRow) as? DiffOutlineItem,
            let file = item.fileDiff
        else { return }
        onSelect(file)
    }
}

/// A tree row whose selection fill is the theme accent, not macOS's system-blue highlight — the
/// chrome must never show a color that doesn't follow `Theme.current` (ZEN-27). Matches the command
/// palette's selection tint (accent at low alpha).
private final class ThemedSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.current.chrome.accent.nsColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// One reused row of the file tree: the file (or directory) name, and for a file the `+n −m`
/// add/remove stat in the positive/destructive roles. Manual `frame` layout (no per-row Auto
/// Layout) so scrolling a large tree stays cheap, mirroring the diff pane's cell.
private final class DiffTreeRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let statLabel = NSTextField(labelWithString: "")
    private var hasStat = false

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        statLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        addSubview(nameLabel)
        addSubview(statLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ item: DiffOutlineItem) {
        let chrome = Theme.current.chrome
        nameLabel.stringValue = item.displayName
        nameLabel.textColor = item.isDirectory ? chrome.ink(alpha: 0.7) : chrome.foreground.nsColor
        hasStat = !item.isDirectory && (item.addedCount + item.removedCount > 0)
        statLabel.isHidden = !hasStat
        if hasStat {
            statLabel.attributedStringValue = Self.statText(
                added: item.addedCount, removed: item.removedCount, chrome: chrome)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let statWidth = hasStat ? statLabel.intrinsicContentSize.width : 0
        let gap: CGFloat = hasStat ? 8 : 0
        statLabel.frame = NSRect(x: bounds.width - statWidth, y: 0, width: statWidth, height: bounds.height)
        nameLabel.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - statWidth - gap), height: bounds.height)
    }

    private static func statText(added: Int, removed: Int, chrome: ChromeTheme) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if added > 0 {
            text.append(
                NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: chrome.positive.nsColor]))
        }
        if removed > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(
                NSAttributedString(string: "−\(removed)", attributes: [.foregroundColor: chrome.destructive.nsColor]))
        }
        return text
    }
}
