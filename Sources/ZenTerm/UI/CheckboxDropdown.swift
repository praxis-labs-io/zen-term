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

    private var rowViews: [CheckboxRowView] = []

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
        let chrome = Theme.current.chrome
        for (row, index) in zip(rowViews, visible) {
            guard items.indices.contains(index) else { continue }
            row.render(item: items[index], isHighlighted: isPopoverOpen && index == highlighted, chrome: chrome)
        }
    }

    override func itemRows() -> [ListPopover.Row] {
        rowViews = visible.map { index in CheckboxRowView { [weak self] in self?.pick(index) } }
        return rowViews.map { ListPopover.Row(view: $0, height: Self.rowHeight) }
    }

    private final class CheckboxRowView: NSView {
        private let onClick: () -> Void
        private let check = NSImageView()
        private let title = NSTextField(labelWithString: "")
        private let note = NSTextField(labelWithString: "")
        private let icon = NSImageView()
        private lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: 0)
        private lazy var titleGap = title.leadingAnchor.constraint(equalTo: icon.trailingAnchor)

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = ChromeMetrics.Radius.control
            translatesAutoresizingMaskIntoConstraints = false

            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check.symbolConfiguration = .init(pointSize: ChromeMetrics.Icon.sm, weight: .semibold)
            check.translatesAutoresizingMaskIntoConstraints = false
            title.font = ChromeType.font(.body)
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            note.font = ChromeType.font(.caption)
            note.translatesAutoresizingMaskIntoConstraints = false
            note.setContentCompressionResistancePriority(.required, for: .horizontal)
            icon.symbolConfiguration = .init(pointSize: ChromeMetrics.Icon.sm, weight: .regular)
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(check)
            addSubview(icon)
            addSubview(title)
            addSubview(note)
            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
                check.widthAnchor.constraint(equalToConstant: 14),
                check.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: ChromeMetrics.Spacing.s6),
                iconWidth,
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleGap,
                title.trailingAnchor.constraint(
                    lessThanOrEqualTo: note.leadingAnchor, constant: -ChromeMetrics.Spacing.s8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
                note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
                note.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func render(item: CheckboxDropdownItem, isHighlighted: Bool, chrome: ChromeTheme) {
            title.stringValue = item.title
            title.textColor = item.isChecked ? chrome.ink(.normal) : chrome.ink(.muted)
            note.stringValue = item.note ?? ""
            note.textColor = chrome.ink(.faint)
            note.isHidden = item.note == nil
            icon.image = item.symbol.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            icon.contentTintColor = item.isChecked ? chrome.ink(.normal) : chrome.ink(.subtle)
            icon.isHidden = item.symbol == nil
            iconWidth.constant = icon.isHidden ? 0 : 14
            titleGap.constant = icon.isHidden ? 0 : ChromeMetrics.Spacing.s6
            check.isHidden = !item.isChecked
            check.contentTintColor = chrome.ink(.normal)
            layer?.backgroundColor = (isHighlighted ? chrome.fill(.hover) : NSColor.clear).cgColor
        }

        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
