import AppKit

/// Shared horizontal metrics so the selection pill and the row content agree on where the pill's inner
/// edge sits. The pill is inset symmetrically from the row's edges; content must stop inside that inner
/// edge rather than run to the row edge (past the pill) and hug its border.
private enum DiffRowMetrics {
    /// Pill inset from the row's left/right edges — the symmetric gap between the pill and the column
    /// edge on the left and the tree divider on the right.
    static let pillInset: CGFloat = 6
    /// Trailing inset for row content: clears the pill's inner edge plus a little text padding, so a
    /// truncated name stops inside the pill instead of touching its right border.
    static let contentTrailing: CGFloat = pillInset + 4
}

/// The data source + delegate for the diff viewer's file tree: three top-level section rows
/// (Unstaged / Staged / Committed), each holding a folded file tree. A single flexible column — the
/// indented name — takes the full width; a file's change magnitude reads from its status-tinted icon
/// (added / deleted / renamed / modified), and a section header carries its slice's `+n −m` line total
/// (the footer shows the repo name and branch, not a grand total). Selecting a file reports it through
/// `onSelect`; a section or directory just doesn't change the diff. Row views are reused and read
/// `Theme.current` at configure time, so a live theme swap (`reloadData`) recolors.
final class DiffTreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private(set) var roots: [DiffOutlineItem]
    private let onSelect: (FileDiff) -> Void

    static let nameColumnID = NSUserInterfaceItemIdentifier("diff-name")

    private static let rowID = NSUserInterfaceItemIdentifier("diff-tree-row")
    private static let sectionID = NSUserInterfaceItemIdentifier("diff-tree-section")
    private static let selectionRowID = NSUserInterfaceItemIdentifier("diff-tree-selection")

    init(sections: [DiffOutlineItem], onSelect: @escaping (FileDiff) -> Void) {
        self.roots = sections
        self.onSelect = onSelect
    }

    /// Every file row in tree order — the rows a selection can land on. The first is where a load with
    /// nothing to restore lands; the whole list is what a restored selection is matched against (ZEN-233).
    var fileItems: [DiffOutlineItem] {
        func leaves(in items: [DiffOutlineItem]) -> [DiffOutlineItem] {
            items.flatMap { $0.fileDiff != nil ? [$0] : leaves(in: $0.children) }
        }
        return leaves(in: roots)
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

/// A tree row whose selection fill is the theme accent, not macOS's system-blue highlight (ZEN-27).
/// Solid accent fill while the tree holds focus; a quiet outline while the diff does, so the selected
/// file stays marked without competing with the diff's own cursor line.
private final class ThemedSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let accent = Theme.current.chrome.accent.nsColor
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: DiffRowMetrics.pillInset, dy: 1), xRadius: 6, yRadius: 6)
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

/// A section header row: the slice name (Unstaged / Staged / Committed) in muted small caps, with the
/// slice's `+n −m` line total inline right after it — the grand total lives in the footer, this scopes
/// it per section so each slice reads its own magnitude at a glance. Title and stat share one label (one
/// attributed string) so the badge rides in the title's own frame and can't be clipped by its own math.
private final class DiffSectionRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")

    // The outline already frames this cell clear of the disclosure triangle, so a small inset is all
    // it takes — matching where the file/folder rows sit their icon, so the section title reads as
    // tight to its chevron as the files do to theirs (not floating far to the right).
    private static let leadingInset: CGFloat = 2

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ item: DiffOutlineItem) {
        let line = NSMutableAttributedString(
            string: item.displayName.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Theme.current.chrome.ink(alpha: 0.55),
            ])
        let stat = DiffStatText.attributed(added: item.addedCount, removed: item.removedCount)
        if stat.length > 0 {
            line.append(NSAttributedString(string: "   ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
            line.append(stat)
        }
        titleLabel.attributedStringValue = line
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleHeight = titleLabel.intrinsicContentSize.height
        // Clamp to the cell's real width, same as `DiffTreeRowView` — `NavOutlineView.layout()`
        // (DiffViewerOverlay.swift) is what makes that width trustworthy (ZEN-226).
        titleLabel.frame = NSRect(
            x: Self.leadingInset, y: ((bounds.height - titleHeight) / 2).rounded(),
            width: max(0, bounds.width - Self.leadingInset - DiffRowMetrics.contentTrailing),
            height: titleHeight)
    }
}

/// One reused row of the file tree: a status-tinted file (or folder) icon and the name. Manual `frame`
/// layout (no per-row Auto Layout) so scrolling a large tree stays cheap. A name the column had to clip
/// reveals its full self in a branded hover tooltip.
private final class DiffTreeRowView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var tooltip = TooltipHost(label: "")
    private var trackingArea: NSTrackingArea?

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
        // Rows are reused across scroll positions, so the tooltip label has to be reassigned every
        // configure — otherwise a recycled row names the wrong file on hover. Dismiss any tooltip the
        // old host is still showing first (a `reloadData` can reconfigure the row under the pointer),
        // so a stale label can't linger past the swap.
        tooltip.hide(from: self)
        tooltip = TooltipHost(label: item.displayName)
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
            width: max(0, bounds.width - nameX - DiffRowMetrics.contentTrailing), height: nameHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // Only a name the column actually clipped earns a tooltip — a fully-visible one doesn't need one.
    override func mouseEntered(with event: NSEvent) {
        if nameLabel.intrinsicContentSize.width > nameLabel.frame.width + 0.5 { tooltip.show(from: self) }
    }
    override func mouseExited(with event: NSEvent) { tooltip.hide(from: self) }

    /// Drop the tooltip if the row leaves the window (the tree rebuilds on a reload).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }
}
