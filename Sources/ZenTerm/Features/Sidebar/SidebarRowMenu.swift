import AppKit

// A sidebar row's menu, opened by right-click or ⌘K: a click or ↑/↓ and Return picks an item.
@MainActor
final class SidebarRowMenu {
    struct Item {
        let title: String
        let action: KeyInterceptor.ReservedChord?
        let run: () -> Void
    }

    private static let rowHeight: CGFloat = ChromeMetrics.Height.control
    private static let separatorHeight: CGFloat = ChromeMetrics.Spacing.s6

    private static func separator() -> NSView {
        let row = NSView()
        let line = Divider()
        row.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private static func content(_ item: Item) -> ListRow.Content {
        let shortcut = item.action.map { CommandCatalog.spec(for: $0).shortcut } ?? ""
        return ListRow.Content(title: item.title, trailing: shortcut.isEmpty ? nil : .keycap(shortcut))
    }

    private var popover: ListPopover?
    private(set) weak var anchor: NSView?
    private var itemViews: [ListRow] = []
    private var highlighted: Int?

    var isOpen: Bool { popover?.isOpen == true }

    var onOpenChanged: ((Bool) -> Void)?
    // Not `isOpen`: ListPopover's own close clears the card before calling back, so by then the menu reads shut.
    private var hasIssuedCover = false

    func open(_ groups: [[Item]], from row: NSView, highlightingFirst: Bool = false) {
        close()
        let groups = groups.filter { !$0.isEmpty }
        guard !groups.isEmpty, row.window != nil else { return }
        let popover = ListPopover(anchor: row)
        popover.onSelfClose = { [weak self] in self?.close() }
        var rows: [ListPopover.Row] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { rows.append(ListPopover.Row(view: Self.separator(), height: Self.separatorHeight)) }
            let views = group.map { item in
                ListRow(Self.content(item)) { [weak self] in
                    self?.close()
                    item.run()
                }
            }
            itemViews += views
            rows += views.map { ListPopover.Row(view: $0, height: Self.rowHeight) }
        }
        popover.open(rows: rows)
        self.popover = popover
        anchor = row
        hasIssuedCover = true
        onOpenChanged?(true)
        if highlightingFirst { moveHighlight(1) }
    }

    func close() {
        let hadCover = hasIssuedCover
        hasIssuedCover = false
        defer { if hadCover { onOpenChanged?(false) } }
        popover?.close()
        popover = nil
        anchor = nil
        itemViews = []
        highlighted = nil
    }

    // The keyboard cursor suppresses hover, or the hovered item and the cursor's item would both look chosen.
    func moveHighlight(_ delta: Int) {
        guard isOpen, let next = KeyboardFocus.step(from: highlighted, delta: delta, count: itemViews.count)
        else { return }
        highlighted = next
        for (index, row) in itemViews.enumerated() {
            row.setHoverSuppressed(true)
            row.isHighlighted = index == next
        }
    }

    func chooseHighlighted() {
        guard isOpen, let highlighted, itemViews.indices.contains(highlighted) else { return }
        itemViews[highlighted].onChoose()
    }

    var itemViewsForTesting: [ListRow] { itemViews }
    var highlightedTitleForTesting: String? { highlighted.map { itemViews[$0].title } }
}
