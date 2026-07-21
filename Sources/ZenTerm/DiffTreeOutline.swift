import AppKit

/// A reference-typed node the `NSOutlineView` can hold by identity. `DiffTreeNode` is a value
/// enum, and an outline view keys its rows on object identity (expansion state, selection), so a
/// freshly-boxed value each call would break it. This wraps the tree once into stable objects.
final class DiffOutlineItem {
    enum Kind {
        case directory(String)
        case file(FileDiff)
    }
    let kind: Kind
    let children: [DiffOutlineItem]

    init(node: DiffTreeNode) {
        switch node {
        case .directory(let name, let nodes):
            kind = .directory(name)
            children = nodes.map(DiffOutlineItem.init)
        case .file(let file):
            kind = .file(file)
            children = []
        }
    }

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    var fileDiff: FileDiff? {
        if case .file(let file) = kind { return file }
        return nil
    }

    var displayName: String {
        switch kind {
        case .directory(let name): return name
        case .file(let file): return String(file.path.split(separator: "/").last ?? Substring(file.path))
        }
    }

    /// Build the outline's root items from a flat file list, folding through the shared `DiffTree`.
    static func roots(from files: [FileDiff]) -> [DiffOutlineItem] {
        DiffTree.build(files).map(DiffOutlineItem.init)
    }
}

/// The data source + delegate for the diff viewer's left file tree. Renders each row as a name
/// plus a themed `+n −m` stat, and reports the selected file back through `onSelect`. Colors are
/// read fresh from `Theme.current` on every row build, so a live theme swap (`reloadData`) recolors.
final class DiffTreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let roots: [DiffOutlineItem]
    private let onSelect: (FileDiff) -> Void

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
        return DiffTreeRowView(item: node)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedSelectionRowView()
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

/// One row of the file tree: the file (or directory) name, and for a file the `+n −m` add/remove
/// stat in the positive/destructive roles.
private final class DiffTreeRowView: NSView {
    init(item: DiffOutlineItem) {
        super.init(frame: .zero)
        let chrome = Theme.current.chrome

        let name = NSTextField(labelWithString: item.displayName)
        name.font = .systemFont(ofSize: 12)
        name.textColor = item.isDirectory ? chrome.ink(alpha: 0.7) : chrome.foreground.nsColor
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if let file = item.fileDiff, file.addedCount + file.removedCount > 0 {
            let stat = NSTextField(labelWithString: "")
            stat.attributedStringValue = Self.statText(
                added: file.addedCount, removed: file.removedCount, chrome: chrome)
            stat.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            stat.setContentCompressionResistancePriority(.required, for: .horizontal)
            stat.setContentHuggingPriority(.required, for: .horizontal)
            stat.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stat)
            NSLayoutConstraint.activate([
                stat.centerYAnchor.constraint(equalTo: centerYAnchor),
                stat.trailingAnchor.constraint(equalTo: trailingAnchor),
                stat.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            ])
        } else {
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
