import AppKit

struct DropdownItem: Equatable {
    let title: String
    let group: String?
    let note: String?
    let isSelected: Bool
    let swatch: NSColor?

    init(title: String, group: String?, note: String?, isSelected: Bool, swatch: NSColor? = nil) {
        self.title = title
        self.group = group
        self.note = note
        self.isSelected = isSelected
        self.swatch = swatch
    }
}

final class Dropdown: PopoverPicker {
    private(set) var selectedIndex: Int
    private var items: [DropdownItem]
    private let onChange: (Int) -> Void

    private let swatch = NSView()
    private var titleAfterSwatch = NSLayoutConstraint()
    private var rowViews: [(index: Int, row: ListRow)] = []

    private static let headerHeight: CGFloat = ChromeMetrics.Height.xs

    var itemsForTesting: [DropdownItem] { items }
    var highlightedRowForTesting: NSView? { highlightedRow() }
    var rowViewsForTesting: [ListRow] { rowViews.map(\.row) }
    var isHighlightedRowVisibleForTesting: Bool {
        guard let row = highlightedRow(), let clip = row.enclosingScrollView?.contentView else { return false }
        return clip.bounds.intersects(row.convert(row.bounds, to: clip))
    }
    var rowFillsForTesting: [NSColor?] {
        rowViews.map { $0.row.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    }

    init(items: [DropdownItem], selectedIndex: Int, onChange: @escaping (Int) -> Void) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.onChange = onChange
        super.init()

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = ChromeMetrics.Radius.capsule(ListRow.swatchSize)
        swatch.layer?.borderWidth = ChromeMetrics.Border.width
        swatch.layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.swatchRing).cgColor
        swatch.isHidden = true
        swatch.translatesAutoresizingMaskIntoConstraints = false

        addSubview(swatch)
        titleAfterSwatch = titleLabel.leadingAnchor.constraint(
            equalTo: swatch.trailingAnchor, constant: ChromeMetrics.Spacing.s6)
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: ListRow.swatchSize),
            swatch.heightAnchor.constraint(equalToConstant: ListRow.swatchSize),
        ])
        renderSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setItems(_ items: [DropdownItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = min(max(selectedIndex, 0), max(0, items.count - 1))
        renderSelection()
    }

    private func renderSelection() {
        let item = items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
        title = item?.title ?? ""
        swatch.layer?.backgroundColor = item?.swatch?.cgColor
        swatch.isHidden = item?.swatch == nil
        titleAfterSwatch.isActive = false
        titleLeading.isActive = false
        (swatch.isHidden ? titleLeading : titleAfterSwatch).isActive = true
    }

    override func reapplyTheme() {
        swatch.layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.swatchRing).cgColor
        super.reapplyTheme()
    }

    override func itemTitles() -> [String] { items.map(\.title) }

    override func openingHighlight() -> Int { selectedIndex }

    override func pick(_ index: Int) {
        selectedIndex = index
        renderSelection()
        closeList()
        onChange(selectedIndex)
        window?.makeFirstResponder(self)
    }

    override func listDidClose() { rowViews = [] }

    override func highlightedRow() -> NSView? { rowViews.first { $0.index == highlighted }?.row }

    override func renderRows() {
        for (index, row) in rowViews { row.isHighlighted = index == highlighted }
    }

    override func itemRows() -> [ListPopover.Row] {
        rowViews = []
        var lines: [ListPopover.Row] = []
        var previousGroup: String?
        for index in visible {
            let item = items[index]
            if query.isEmpty, let group = item.group, group != previousGroup {
                lines.append(ListPopover.Row(view: Self.groupHeaderView(group), height: Self.headerHeight))
            }
            previousGroup = item.group
            let content = ListRow.Content(
                title: item.title, note: item.note, leading: item.swatch.map { .swatch($0) },
                trailing: item.isSelected ? .check : nil)
            let row = ListRow(content) { [weak self] in self?.pick(index) }
            row.onPointerEnter = { [weak self] in self?.highlightPointed(index) }
            rowViews.append((index, row))
            lines.append(ListPopover.Row(view: row, height: Self.rowHeight))
        }
        return lines
    }

    private static func groupHeaderView(_ text: String) -> NSView {
        let label = SectionCaption(text)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        return host
    }
}
