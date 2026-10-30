import AppKit

final class IconPickerField: NSView, ThemeReapplying {
    private(set) var selected: String
    var onChange: ((String) -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private let glyph = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var isFocusedStop = false { didSet { restyle() } }

    private lazy var popover: ListPopover = {
        let popover = ListPopover(anchor: self)
        popover.onSelfClose = { [weak self] in
            self?.cells = []
            self?.restyle()
        }
        return popover
    }()
    private let sections: [IconCatalog.Section]
    private let orderedSymbols: [String]
    /// Vertical nav walks rows, not a column stride, because a "Current" section is a row of one.
    private let rows: [Range<Int>]
    private var cells: [IconButton] = []
    private var highlighted = 0

    private static let columns = 8
    static var columnsForTesting: Int { columns }
    private static let cellSize = ChromeMetrics.Height.lg
    private static let cellSpacing: CGFloat = ChromeMetrics.Spacing.s4
    private static let headerHeight: CGFloat = ChromeMetrics.Height.xs
    private static let sectionGap: CGFloat = ChromeMetrics.Spacing.s12
    private static var restFill: NSColor { Theme.current.chrome.fill(.rest) }

    func openForTesting() { openPopover() }
    var highlightedSymbolForTesting: String? {
        orderedSymbols.indices.contains(highlighted) ? orderedSymbols[highlighted] : nil
    }
    var cellCountForTesting: Int { cells.count }
    var highlightedCellForTesting: NSView? { cells.indices.contains(highlighted) ? cells[highlighted] : nil }
    func moveHighlightForTesting(_ delta: Int) { moveHighlight(delta) }
    func moveVerticallyForTesting(_ rows: Int) { moveVertically(rows) }
    func commitHighlightForTesting() { commitHighlight() }

    init(selected: String) {
        let initial = selected.isEmpty ? IconCatalog.defaultSymbol : selected
        sections = IconCatalog.sections(including: initial)
        orderedSymbols = sections.flatMap(\.symbols)
        var bounds: [Range<Int>] = []
        var start = 0
        for section in sections {
            for chunk in stride(from: 0, to: section.symbols.count, by: Self.columns) {
                let length = min(Self.columns, section.symbols.count - chunk)
                bounds.append(start..<(start + length))
                start += length
            }
        }
        rows = bounds
        self.selected = initial
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        layer?.borderWidth = ChromeMetrics.Border.width

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.font = ChromeType.font(.body)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: ChromeMetrics.Icon.xs, weight: .semibold)
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph)
        addSubview(nameLabel)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.control),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: ChromeMetrics.Spacing.s8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: ChromeMetrics.Spacing.s6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        renderClosed()
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        restyle()
        renderClosed()
        guard popover.isOpen else { return }
        let kept = highlighted
        closePopover()
        openPopover()
        highlighted = kept
        refreshHighlight()
        if cells.indices.contains(kept) { popover.reveal(cells[kept]) }
    }

    private func renderClosed() {
        glyph.image = IconCatalog.image(selected)
        glyph.contentTintColor = Theme.current.chrome.ink(.normal)
        nameLabel.stringValue = IconCatalog.displayName(selected)
        nameLabel.textColor = Theme.current.chrome.ink(.normal)
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        let active = isFocusedStop || popover.isOpen
        layer?.backgroundColor = Self.restFill.cgColor
        layer?.borderColor = (active ? chrome.focusRing : chrome.fill(alpha: ChromeTheme.border)).cgColor
        layer?.borderWidth = ChromeMetrics.Border.width
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocusedStop = true; return true }
    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        closePopover()
        return super.resignFirstResponder()
    }
    override func drawFocusRingMask() {}

    /// The card lives on the content view, so it closes here or a tab switch strands it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closePopover() }
    }

    /// Esc closes the grid here: a bare Esc reaches `keyDown` before the card root's `performKeyEquivalent`.
    override func keyDown(with event: NSEvent) {
        if popover.isOpen {
            switch KeyboardFocus.key(for: event) {
            case .left: moveHighlight(-1)
            case .right: moveHighlight(1)
            case .up: moveVertically(-1)
            case .down: moveVertically(1)
            case .activate: commitHighlight()
            case .escape: closePopover()
            default: break
            }
            return
        }
        switch KeyboardFocus.key(for: event) {
        case .activate: openPopover()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        popover.isOpen ? closePopover() : openPopover()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    var isPopoverOpen: Bool { popover.isOpen }

    private func closePopover() {
        popover.close()
        cells = []
        restyle()
    }

    private func openPopover() {
        guard !popover.isOpen, window?.contentView != nil else { return }
        highlighted = max(0, orderedSymbols.firstIndex(of: selected) ?? 0)
        popover.open(content: buildGrid())
        refreshHighlight()
        restyle()
    }

    private func buildGrid() -> NSStackView {
        cells = []

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = Self.cellSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false

        var previousRow: NSView?
        for (sectionIndex, section) in sections.enumerated() {
            let header = Self.sectionHeader(section.title)
            grid.addArrangedSubview(header)
            if sectionIndex > 0, let previousRow {
                grid.setCustomSpacing(Self.sectionGap, after: previousRow)
            }
            var row: NSStackView?
            for (index, symbol) in section.symbols.enumerated() {
                if index % Self.columns == 0 {
                    let newRow = NSStackView()
                    newRow.orientation = .horizontal
                    newRow.spacing = Self.cellSpacing
                    grid.addArrangedSubview(newRow)
                    row = newRow
                }
                let cell = IconButton(
                    symbol: symbol, size: NSSize(width: Self.cellSize, height: Self.cellSize),
                    pointSize: ChromeMetrics.Icon.md, accessibilityLabel: IconCatalog.displayName(symbol)
                ) { [weak self] in self?.commit(symbol) }
                row?.addArrangedSubview(cell)
                cells.append(cell)
            }
            previousRow = row
        }
        return grid
    }

    private static func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = ChromeType.sectionLabel
        label.textColor = Theme.current.chrome.ink(.muted)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: headerHeight).isActive = true
        return label
    }

    private func moveVertically(_ delta: Int) {
        guard !cells.isEmpty, let row = rows.firstIndex(where: { $0.contains(highlighted) })
        else { return }
        let column = highlighted - rows[row].lowerBound
        let target = rows[min(max(row + delta, 0), rows.count - 1)]
        highlighted = target.lowerBound + min(column, target.count - 1)
        refreshHighlight()
        popover.reveal(cells[highlighted])
    }

    private func moveHighlight(_ delta: Int) {
        guard !cells.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), cells.count - 1)
        refreshHighlight()
        popover.reveal(cells[highlighted])
    }

    private func refreshHighlight() {
        for (index, cell) in cells.enumerated() {
            cell.isActive = index == highlighted
            cell.layer?.cornerRadius = ChromeMetrics.Radius.control
        }
    }

    private func commitHighlight() {
        guard cells.indices.contains(highlighted) else { return }
        commit(orderedSymbols[highlighted])
    }

    private func commit(_ symbol: String) {
        selected = symbol
        renderClosed()
        closePopover()
        window?.makeFirstResponder(self)
        onChange?(symbol)
    }
}
