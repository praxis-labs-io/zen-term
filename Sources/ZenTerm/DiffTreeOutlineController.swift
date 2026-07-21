import AppKit

/// The data source + delegate for the diff viewer's file tree: three top-level section rows
/// (Unstaged / Staged / Committed), each holding a folded file tree. Section rows aren't selectable;
/// selecting a file reports it through `onSelect`. Row views are reused and read `Theme.current` at
/// configure time, so a live theme swap (`reloadData`) recolors.
final class DiffTreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private(set) var roots: [DiffOutlineItem]
    private let onSelect: (FileDiff) -> Void

    private static let rowID = NSUserInterfaceItemIdentifier("diff-tree-row")
    private static let sectionID = NSUserInterfaceItemIdentifier("diff-tree-section")
    private static let selectionRowID = NSUserInterfaceItemIdentifier("diff-tree-selection")

    init(sections: [DiffOutlineItem], onSelect: @escaping (FileDiff) -> Void) {
        self.roots = sections
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
        !children(of: item).isEmpty
    }

    private func children(of item: Any?) -> [DiffOutlineItem] {
        guard let item else { return roots }
        return (item as? DiffOutlineItem)?.children ?? []
    }

    // MARK: delegate

    // Every row is selectable — including section headers and directories — so the arrow keys can
    // land on them and Left/Right fold them. Selecting a non-file row just doesn't change the diff
    // (the selection handler only acts on files).

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DiffOutlineItem else { return nil }
        if node.isSection {
            let row =
                outlineView.makeView(withIdentifier: Self.sectionID, owner: self) as? DiffSectionRowView
                ?? DiffSectionRowView(id: Self.sectionID)
            row.configure(title: node.displayName, subtitle: node.sectionSubtitle)
            return row
        }
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

/// A section header row: the slice name (Unstaged / Staged / Committed) in muted small caps, with an
/// optional trailing subtitle (the fork base for the committed slice). Not selectable.
private final class DiffSectionRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, subtitle: String?) {
        let chrome = Theme.current.chrome
        titleLabel.stringValue = title.uppercased()
        titleLabel.textColor = chrome.ink(alpha: 0.55)
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.textColor = chrome.muted.nsColor
        subtitleLabel.isHidden = subtitle == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: 0, y: ((bounds.height - titleHeight) / 2).rounded(),
            width: titleLabel.intrinsicContentSize.width, height: titleHeight)
        let subtitleWidth = subtitleLabel.isHidden ? 0 : subtitleLabel.intrinsicContentSize.width
        let subtitleHeight = subtitleLabel.intrinsicContentSize.height
        subtitleLabel.frame = NSRect(
            x: bounds.width - subtitleWidth, y: ((bounds.height - subtitleHeight) / 2).rounded(),
            width: subtitleWidth, height: subtitleHeight)
    }
}

/// One reused row of the file tree: the file (or directory) name, and for a file the `+n −m`
/// add/remove stat in the positive/destructive roles. Manual `frame` layout (no per-row Auto Layout)
/// so scrolling a large tree stays cheap, mirroring the diff pane's cell.
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
        // NSTextField top-aligns single-line text in a taller frame, so size each label to its own
        // height and center it — otherwise the name rides high in the selection highlight.
        let nameHeight = nameLabel.intrinsicContentSize.height
        let statHeight = statLabel.intrinsicContentSize.height
        statLabel.frame = NSRect(
            x: bounds.width - statWidth, y: ((bounds.height - statHeight) / 2).rounded(),
            width: statWidth, height: statHeight)
        nameLabel.frame = NSRect(
            x: 0, y: ((bounds.height - nameHeight) / 2).rounded(),
            width: max(0, bounds.width - statWidth - gap), height: nameHeight)
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
