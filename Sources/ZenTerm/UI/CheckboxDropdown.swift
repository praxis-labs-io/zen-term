import AppKit

struct CheckboxDropdownItem: Equatable {
    let title: String
    let isChecked: Bool
    let note: String?
    let symbol: String?

    init(title: String, isChecked: Bool, note: String? = nil, symbol: String? = nil) {
        self.title = title
        self.isChecked = isChecked
        self.note = note
        self.symbol = symbol
    }
}

final class CheckboxDropdown: PopoverPicker {
    private(set) var items: [CheckboxDropdownItem]
    private let onToggle: (Int) -> Void
    /// Fixed at init; `setItems` clamps to it so arrowing never reaches a row that was not rendered.
    private let rowCount: Int

    var onClosed: (() -> Void)?
    var restingIndices: [Int]?

    private var rowViews: [ListRow] = []

    var shownSummaryForTesting: String? { titleLabel.isHidden ? nil : titleLabel.stringValue }
    var itemsForTesting: [CheckboxDropdownItem] { items }
    var rowViewsForTesting: [NSView] { rowViews }

    init(title: String, items: [CheckboxDropdownItem], onToggle: @escaping (Int) -> Void) {
        self.items = items
        self.rowCount = items.count
        self.onToggle = onToggle
        super.init()
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setItems(_ items: [CheckboxDropdownItem], title: String) {
        self.items = Array(items.prefix(rowCount))
        self.title = title
        renderRows()
    }

    override func itemTitles() -> [String] { items.map(\.title) }

    override func restingOrder() -> [Int] {
        restingIndices.map { $0.filter(items.indices.contains) } ?? Array(items.indices)
    }

    override func pick(_ index: Int) {
        guard items.indices.contains(index) else { return }
        highlighted = index
        onToggle(index)
        renderRows()
    }

    override func listDidClose() {
        rowViews = []
        guard let closed = onClosed else { return }
        onClosed = nil
        closed()
    }

    override func highlightedRow() -> NSView? {
        guard let position = visible.firstIndex(of: highlighted), rowViews.indices.contains(position) else {
            return nil
        }
        return rowViews[position]
    }

    override func renderRows() {
        for (row, index) in zip(rowViews, visible) {
            guard items.indices.contains(index) else { continue }
            row.render(Self.content(items[index]))
            row.isHighlighted = isPopoverOpen && index == highlighted
        }
    }

    override func itemRows() -> [ListPopover.Row] {
        rowViews = visible.map { index in
            let content = items.indices.contains(index) ? Self.content(items[index]) : ListRow.Content(title: "")
            let row = ListRow(content) { [weak self] in self?.pick(index) }
            row.onPointerEnter = { [weak self] in self?.highlightPointed(index) }
            return row
        }
        return rowViews.map { ListPopover.Row(view: $0, height: Self.rowHeight) }
    }

    private static func content(_ item: CheckboxDropdownItem) -> ListRow.Content {
        ListRow.Content(
            title: item.title, note: item.note, leading: item.symbol.map { .symbol($0) },
            trailing: item.isChecked ? .check : nil, ink: item.isChecked ? .normal : .muted)
    }
}
