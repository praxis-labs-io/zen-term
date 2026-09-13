import AppKit

final class IconPickerField: NSView {
    private(set) var selected: String
    var onChange: ((String) -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private let glyph = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var isFocusedStop = false { didSet { restyle() } }

    private var popover: NSView?
    private var resizeObserver: NSObjectProtocol?
    private let sections: [IconCatalog.Section]
    private let orderedSymbols: [String]
    /// Vertical nav walks rows, not a column stride, because a "Current" section is a row of one.
    private let rows: [Range<Int>]
    private var cells: [IconButton] = []
    private var highlighted = 0

    private static let columns = 8
    static var columnsForTesting: Int { columns }
    private static let cellSize: CGFloat = 34
    private static let cellSpacing: CGFloat = 4
    private static let headerHeight: CGFloat = 16
    private static let sectionGap: CGFloat = 12
    private static let windowMargin: CGFloat = 8
    /// Overlay scrollers draw over content, so without this lane the bar covers the last column.
    private static let scrollerGutter: CGFloat = 16
    private var cardNaturalSize: NSSize = .zero
    private static var restFill: NSColor { Theme.current.chrome.fill(.rest) }
    private static var focusFill: NSColor { Theme.current.chrome.selectionFill }

    func openForTesting() { openPopover() }
    var highlightedSymbolForTesting: String? {
        orderedSymbols.indices.contains(highlighted) ? orderedSymbols[highlighted] : nil
    }
    var cellCountForTesting: Int { cells.count }
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
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = Theme.current.chrome.ink(.muted)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph)
        addSubview(nameLabel)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        renderClosed()
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    func reapplyTheme() {
        restyle()
        renderClosed()
    }

    private func renderClosed() {
        glyph.image = IconCatalog.image(selected)
        glyph.contentTintColor = Theme.current.chrome.foreground.nsColor
        nameLabel.stringValue = IconCatalog.displayName(selected)
        nameLabel.textColor = Theme.current.chrome.foreground.nsColor
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        let active = isFocusedStop || popover != nil
        layer?.backgroundColor = (active ? Self.focusFill : Self.restFill).cgColor
        layer?.borderColor = (active ? chrome.accent.nsColor : chrome.fill(alpha: ChromeTheme.border)).cgColor
        layer?.borderWidth = active ? 1.5 : 1
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
        if popover != nil {
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
        popover == nil ? openPopover() : closePopover()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    var isPopoverOpen: Bool { popover != nil }

    private func closePopover() {
        popover?.removeFromSuperview()
        popover = nil
        cells = []
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        restyle()
    }

    private func observeResize(of window: NSWindow?) {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
    }

    private func openPopover() {
        guard popover == nil, let contentView = window?.contentView else { return }
        highlighted = max(0, orderedSymbols.firstIndex(of: selected) ?? 0)
        let card = buildPopover()
        contentView.addSubview(card)
        popover = card
        positionPopover()
        observeResize(of: window)
        refreshHighlight()
        restyle()
    }

    private func buildPopover() -> NSView {
        let chrome = Theme.current.chrome
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
                    pointSize: 15, accessibilityLabel: IconCatalog.displayName(symbol)
                ) { [weak self] in self?.commit(symbol) }
                row?.addArrangedSubview(cell)
                cells.append(cell)
            }
            previousRow = row
        }

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let card = ShadowCardView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = chrome.background.nsColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        card.translatesAutoresizingMaskIntoConstraints = true
        FloatShadow.applyShadow(to: card)
        card.addSubview(scroll)

        let inset: CGFloat = 8
        let gridWidth = CGFloat(Self.columns) * Self.cellSize + CGFloat(Self.columns - 1) * Self.cellSpacing
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.topAnchor.constraint(equalTo: doc.topAnchor),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        grid.layoutSubtreeIfNeeded()
        cardNaturalSize = NSSize(
            width: gridWidth + inset * 2, height: grid.fittingSize.height + inset * 2)
        card.frame = NSRect(origin: .zero, size: cardNaturalSize)
        return card
    }

    private static func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = Theme.current.chrome.ink(.faint)
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
        cells[highlighted].scrollToVisible(cells[highlighted].bounds)
    }

    private func moveHighlight(_ delta: Int) {
        guard !cells.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), cells.count - 1)
        refreshHighlight()
        cells[highlighted].scrollToVisible(cells[highlighted].bounds)
    }

    private func refreshHighlight() {
        let accent = Theme.current.chrome.accent.nsColor.cgColor
        for (index, cell) in cells.enumerated() {
            cell.isActive = index == highlighted
            cell.layer?.cornerRadius = 6
            cell.layer?.borderWidth = index == highlighted ? 1.5 : 0
            cell.layer?.borderColor = index == highlighted ? accent : nil
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

    private func positionPopover() {
        guard let card = popover, let contentView = window?.contentView else { return }
        card.layoutSubtreeIfNeeded()
        let available = contentView.bounds.height - Self.windowMargin * 2
        let height = min(cardNaturalSize.height, available)
        let scrolls = height < cardNaturalSize.height
        let size = NSSize(
            width: cardNaturalSize.width + (scrolls ? Self.scrollerGutter : 0), height: height)
        let origin = convert(bounds, to: contentView)
        let x = max(8, min(origin.minX, contentView.bounds.width - size.width - 8))
        let below = origin.minY - size.height - 4
        let above = origin.maxY + 4
        let maxY = max(8, contentView.bounds.height - size.height - 8)
        var y = below
        if y < 8 { y = above }
        y = max(8, min(y, maxY))
        card.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
