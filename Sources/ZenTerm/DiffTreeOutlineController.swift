import AppKit

/// The data source + delegate for the diff viewer's file tree: three top-level section rows
/// (Unstaged / Staged / Committed), each holding a folded file tree. The tree has two columns — the
/// name (indented, flexible) and the `+n −m` stat (fixed width, right-aligned) — so the stats line up
/// on a common right edge and never clip, regardless of how deep a file is nested. Selecting a file
/// reports it through `onSelect`; a section or directory just doesn't change the diff. Row views are
/// reused and read `Theme.current` at configure time, so a live theme swap (`reloadData`) recolors.
final class DiffTreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private(set) var roots: [DiffOutlineItem]
    private let onSelect: (FileDiff) -> Void

    static let nameColumnID = NSUserInterfaceItemIdentifier("diff-name")
    static let statColumnID = NSUserInterfaceItemIdentifier("diff-stat")

    private static let rowID = NSUserInterfaceItemIdentifier("diff-tree-row")
    private static let sectionID = NSUserInterfaceItemIdentifier("diff-tree-section")
    private static let statViewID = NSUserInterfaceItemIdentifier("diff-tree-stat")
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
    // land on them and Left/Right fold them. Selecting a non-file row just doesn't change the diff.

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? DiffOutlineItem else { return 20 }
        return node.isSection ? 34 : 20  // the extra height sets each section off from the rows above
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DiffOutlineItem else { return nil }
        if tableColumn?.identifier == Self.statColumnID {
            let cell =
                outlineView.makeView(withIdentifier: Self.statViewID, owner: self) as? DiffStatCellView
                ?? DiffStatCellView(id: Self.statViewID)
            cell.configure(added: node.addedCount, removed: node.removedCount)
            return cell
        }
        if node.isSection {
            let row =
                outlineView.makeView(withIdentifier: Self.sectionID, owner: self) as? DiffSectionRowView
                ?? DiffSectionRowView(id: Self.sectionID)
            row.configure(node)
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

/// The `+n −m` stat in the positive/destructive roles, shared by the file and section stat cells. The
/// font is baked into the attributes, not left to the label's `.font`: an `attributedStringValue`
/// ignores the label's font, so without it the string measures and renders in different fonts.
func diffStatText(added: Int, removed: Int, chrome: ChromeTheme) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let text = NSMutableAttributedString()
    if added > 0 {
        text.append(
            NSAttributedString(
                string: "+\(added)", attributes: [.foregroundColor: chrome.positive.nsColor, .font: font]))
    }
    if removed > 0 {
        if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
        text.append(
            NSAttributedString(
                string: "−\(removed)", attributes: [.foregroundColor: chrome.destructive.nsColor, .font: font]))
    }
    // Bake right-alignment into the string. `attributedStringValue` ignores the label's `.alignment`
    // (the same reason the font is baked in), so with the label filling its cell this is what actually
    // pins the stat flush to the right edge — the `+n`-only case included.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    return text
}

/// The stat column's cell: the `+n −m` total, right-aligned. A fixed-width column, so every stat
/// lines up on the same right edge and the `−m` can't be clipped by a nested file's narrow name cell.
private final class DiffStatCellView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // The label FILLS the cell (leading pinned, not `>=`) so the baked right-alignment has room to
        // push the stat to the trailing edge. When the label only hugged its content, alignment was a
        // no-op and the stat landed wherever the content-sized frame happened to sit — flush for some
        // rows, short of the edge for others.
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(added: Int, removed: Int) {
        if added + removed > 0 {
            label.attributedStringValue = diffStatText(added: added, removed: removed, chrome: Theme.current.chrome)
        } else {
            label.stringValue = ""
        }
    }
}

/// A tree row whose selection fill is the theme accent, not macOS's system-blue highlight (ZEN-27).
/// Solid accent fill while the tree holds focus; a quiet outline while the diff does, so the selected
/// file stays marked without competing with the diff's own cursor line.
private final class ThemedSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let accent = Theme.current.chrome.accent.nsColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6)
        if isEmphasized {
            accent.withAlphaComponent(0.18).setFill()
            path.fill()
        } else {
            accent.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// A section header row (name column): the slice name in muted small caps. The slice total lives in
/// the stat column.
private final class DiffSectionRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")

    // The outline already frames this cell view clear of the disclosure triangle (same as any
    // other row) — this is just extra breathing room so a section title doesn't sit flush against
    // it.
    private static let leadingInset: CGFloat = 16

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ item: DiffOutlineItem) {
        titleLabel.stringValue = item.displayName.uppercased()
        titleLabel.textColor = Theme.current.chrome.ink(alpha: 0.55)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleHeight = titleLabel.intrinsicContentSize.height
        // Clamp to the cell's real width, same as `DiffTreeRowView` — `NavOutlineView.layout()`
        // (DiffViewerOverlay.swift) is what makes that width trustworthy (ZEN-226).
        titleLabel.frame = NSRect(
            x: Self.leadingInset, y: ((bounds.height - titleHeight) / 2).rounded(),
            width: max(0, bounds.width - Self.leadingInset), height: titleHeight)
    }
}

/// One reused row of the file tree (name column): a status-tinted file (or folder) icon and the name.
/// The stat is a separate column. Manual `frame` layout (no per-row Auto Layout) so scrolling a large
/// tree stays cheap.
private final class DiffTreeRowView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    private static let iconWidth: CGFloat = 16

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        iconView.imageScaling = .scaleProportionallyDown
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(iconView)
        addSubview(nameLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ item: DiffOutlineItem) {
        let chrome = Theme.current.chrome
        let icon = Self.icon(for: item, chrome: chrome)
        iconView.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        iconView.contentTintColor = icon.color

        nameLabel.stringValue = item.displayName
        nameLabel.textColor = item.isDirectory ? chrome.ink(alpha: 0.7) : chrome.foreground.nsColor
        needsLayout = true
    }

    /// The SF Symbol + theme tint for a row: a folder for a directory; for a file, a doc tinted by its
    /// change kind — added green, deleted red, renamed accent, modified/binary neutral — with a plus
    /// badge on additions, so new / changed / deleted read at a glance (ZEN-27: all theme roles).
    private static func icon(for item: DiffOutlineItem, chrome: ChromeTheme) -> (symbol: String, color: NSColor) {
        if item.isDirectory { return ("folder", chrome.ink(alpha: 0.5)) }
        switch item.fileDiff?.changeKind {
        case .added: return ("doc.badge.plus", chrome.positive.nsColor)
        case .deleted: return ("doc", chrome.destructive.nsColor)
        case .renamed: return ("doc", chrome.accent.nsColor)
        case .modified, .binary, .none: return ("doc", chrome.ink(alpha: 0.55))
        }
    }

    override func layout() {
        super.layout()
        let icon = Self.iconWidth
        iconView.frame = NSRect(x: 0, y: ((bounds.height - icon) / 2).rounded(), width: icon, height: icon)

        // NSTextField top-aligns single-line text in a taller frame, so size the name to its own
        // height and center it — otherwise it rides high in the selection highlight.
        let nameX = icon + 5
        let nameHeight = nameLabel.intrinsicContentSize.height
        nameLabel.frame = NSRect(
            x: nameX, y: ((bounds.height - nameHeight) / 2).rounded(),
            width: max(0, bounds.width - nameX), height: nameHeight)
    }
}
