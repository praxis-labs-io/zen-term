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
    private var rowViews: [DropdownRowView] = []

    static let swatchSize: CGFloat = 10
    private static let headerHeight: CGFloat = ChromeMetrics.Height.xs

    var itemsForTesting: [DropdownItem] { items }
    var highlightedRowForTesting: NSView? { highlightedRow() }
    var isHighlightedRowVisibleForTesting: Bool {
        guard rowViews.indices.contains(highlighted),
            let clip = rowViews[highlighted].enclosingScrollView?.contentView
        else { return false }
        let row = rowViews[highlighted]
        return clip.bounds.intersects(row.convert(row.bounds, to: clip))
    }
    var rowFillsForTesting: [NSColor?] {
        rowViews.map { $0.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    }

    init(items: [DropdownItem], selectedIndex: Int, onChange: @escaping (Int) -> Void) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.onChange = onChange
        super.init()

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.swatchSize)
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
            swatch.widthAnchor.constraint(equalToConstant: Self.swatchSize),
            swatch.heightAnchor.constraint(equalToConstant: Self.swatchSize),
        ])
        renderSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setItems(_ items: [DropdownItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = min(max(selectedIndex, 0), max(0, items.count - 1))
        renderSelection()
    }

    var titlePrefix: String = "" { didSet { renderSelection() } }

    var titleTruncatesUnderPressure: Bool = false {
        didSet {
            let priority: NSLayoutConstraint.Priority = titleTruncatesUnderPressure ? .defaultLow : .defaultHigh
            titleLabel.setContentCompressionResistancePriority(priority, for: .horizontal)
            setContentCompressionResistancePriority(priority, for: .horizontal)
        }
    }

    private func renderSelection() {
        let item = items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
        title = item.map { titlePrefix + $0.title } ?? ""
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

    override func highlightedRow() -> NSView? { rowViews.first { $0.index == highlighted } }

    override func renderRows() {
        let chrome = Theme.current.chrome
        for row in rowViews { row.setHighlighted(row.index == highlighted, chrome: chrome) }
    }

    override func itemRows() -> [ListPopover.Row] {
        let chrome = Theme.current.chrome
        rowViews = []
        var lines: [ListPopover.Row] = []
        var previousGroup: String?
        for index in visible {
            let item = items[index]
            if query.isEmpty, let group = item.group, group != previousGroup {
                lines.append(
                    ListPopover.Row(
                        view: Self.groupHeaderView(group), height: Self.headerHeight))
            }
            previousGroup = item.group
            let row = DropdownRowView(index: index, item: item, chrome: chrome) { [weak self] i in
                self?.pick(i)
            }
            rowViews.append(row)
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

private final class DropdownRowView: NSView {
    let index: Int
    private let onSelect: (Int) -> Void

    init(index: Int, item: DropdownItem, chrome: ChromeTheme, onSelect: @escaping (Int) -> Void) {
        self.index = index
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = ChromeType.font(.body)
        title.textColor = chrome.ink(.normal)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([title.centerYAnchor.constraint(equalTo: centerYAnchor)])
        if let swatchColor = item.swatch {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = ChromeMetrics.Radius.capsule(Dropdown.swatchSize)
            dot.layer?.backgroundColor = swatchColor.cgColor
            dot.layer?.borderWidth = ChromeMetrics.Border.width
            dot.layer?.borderColor = chrome.fill(alpha: ChromeTheme.swatchRing).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: Dropdown.swatchSize),
                dot.heightAnchor.constraint(equalToConstant: Dropdown.swatchSize),
                title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: ChromeMetrics.Spacing.s6),
            ])
        } else {
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset)
                .isActive = true
        }

        var trailing: [NSView] = []
        if let note = item.note {
            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = ChromeType.font(.caption)
            noteLabel.textColor = chrome.ink(.muted)
            trailing.append(noteLabel)
        }
        if item.isSelected {
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check.symbolConfiguration = .init(pointSize: ChromeMetrics.Icon.sm, weight: .semibold)
            check.contentTintColor = chrome.ink(.normal)
            trailing.append(check)
        }
        if trailing.isEmpty {
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset
            ).isActive = true
        } else {
            let group = NSStackView(views: trailing)
            group.orientation = .horizontal
            group.spacing = ChromeMetrics.Spacing.s6
            group.translatesAutoresizingMaskIntoConstraints = false
            addSubview(group)
            NSLayoutConstraint.activate([
                group.leadingAnchor.constraint(
                    greaterThanOrEqualTo: title.trailingAnchor, constant: ChromeMetrics.Spacing.s8),
                group.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
                group.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { onSelect(index) }

    func setHighlighted(_ isHighlighted: Bool, chrome: ChromeTheme) {
        layer?.backgroundColor = (isHighlighted ? chrome.fill(.hover) : NSColor.clear).cgColor
    }
}
