import AppKit

/// A tool-float icon picker: closed, a `FieldBox`-styled button showing the current glyph + name;
/// Return / Space / click opens a floating card holding an 8-wide grid of curated dev-tooling icons.
/// Arrow keys move the highlight, Return picks it, Esc closes the grid; clicking a cell picks it.
/// A form focus stop — Up/Down bubble to the form while closed. Mirrors `Dropdown`'s window-child
/// floating pattern.
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
    private let sections: [IconCatalog.Section]
    /// The sections flattened in render order, so `cells[i]` is always `orderedSymbols[i]` —
    /// headings are rows in the stack but never cells, so arrow nav steps straight over them.
    private let orderedSymbols: [String]
    private var cells: [IconButton] = []
    private var highlighted = 0

    private static let columns = 8
    /// The grid's width, exposed so `IconCatalogTests` can pin the roster to the real layout
    /// constant rather than a copy of it — the two drifting is what leaves a ragged last row.
    static var columnsForTesting: Int { columns }
    private static let cellSize: CGFloat = 34
    private static let cellSpacing: CGFloat = 4
    private static let headerHeight: CGFloat = 16
    private static let sectionGap: CGFloat = 12
    /// Margin kept between the card and the window edge when the grid is taller than the window.
    private static let windowMargin: CGFloat = 8
    /// A lane for the overlay scroller, added only when the grid is clamped and will scroll.
    /// Overlay scrollers draw *over* content, so without it the bar sits on the last column.
    private static let scrollerGutter: CGFloat = 16
    /// The card at its natural size, before `positionPopover` clamps it to the window.
    private var cardNaturalSize: NSSize = .zero
    private static var restFill: NSColor { Theme.current.chrome.fill(.rest) }
    private static var focusFill: NSColor { Theme.current.chrome.selectionFill }

    /// Test hooks: open the grid and drive it without a live event loop.
    func openForTesting() { openPopover() }
    /// The symbol the highlight currently sits on — the assertion arrow-key tests actually need.
    var highlightedSymbolForTesting: String? {
        orderedSymbols.indices.contains(highlighted) ? orderedSymbols[highlighted] : nil
    }
    var cellCountForTesting: Int { cells.count }
    func moveHighlightForTesting(_ delta: Int) { moveHighlight(delta) }
    func commitHighlightForTesting() { commitHighlight() }

    init(selected: String) {
        let initial = selected.isEmpty ? IconCatalog.defaultSymbol : selected
        // A custom (non-catalog) icon gets its own leading section, so editing a float never drops it.
        sections = IconCatalog.sections(including: initial)
        orderedSymbols = sections.flatMap(\.symbols)
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

    // MARK: focus + keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocusedStop = true; return true }
    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        closePopover()
        return super.resignFirstResponder()
    }
    override func drawFocusRingMask() {}

    /// The grid popover is parented to the window's content view (to escape this field's bounds),
    /// not to this field's subtree — so removing the field, or an ancestor like the workspace /
    /// tool-float form, doesn't take it along. Closing it when the field leaves the window binds the
    /// popover's lifetime to the control, so a tab-switch `closeModal()` can't strand a dead grid on
    /// the content view over every tab (same class as `Dropdown`).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closePopover() }
    }

    override func keyDown(with event: NSEvent) {
        if popover != nil {
            switch KeyboardFocus.key(for: event) {
            case .left: moveHighlight(-1)
            case .right: moveHighlight(1)
            case .up: moveHighlight(-Self.columns)
            case .down: moveHighlight(Self.columns)
            case .activate: commitHighlight()
            // Load-bearing for layered dismissal: a bare Esc reaches this keyDown before any
            // card-root performKeyEquivalent, so closing the grid here leaves the form open. Don't
            // hoist Esc to the card root — that's the dead-end.
            case .escape: closePopover()
            default: break  // consume every other key while the grid is open
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

    // MARK: popover grid

    /// Test hook: whether the icon grid is open right now.
    var isPopoverOpen: Bool { popover != nil }

    private func closePopover() {
        popover?.removeFromSuperview()
        popover = nil
        cells = []
        restyle()
    }

    private func openPopover() {
        guard popover == nil, let contentView = window?.contentView else { return }
        highlighted = max(0, orderedSymbols.firstIndex(of: selected) ?? 0)
        let card = buildPopover()
        contentView.addSubview(card)
        popover = card
        positionPopover()
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
                // IconButton now owns hover labeling via its branded tooltip (the accessibility
                // label above is the glyph name), so no native cell.toolTip is needed.
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
        // Measured off the laid-out stack, not a formula: headings, per-section gaps and the
        // spacing between rows are the stack's arithmetic, and duplicating it here counted one
        // spacing per section too many, leaving dead space under the last row.
        grid.layoutSubtreeIfNeeded()
        cardNaturalSize = NSSize(
            width: gridWidth + inset * 2, height: grid.fittingSize.height + inset * 2)
        // `positionPopover` is where the window is known, so that is where a grid taller than the
        // window gets clamped and left to scroll.
        card.frame = NSRect(origin: .zero, size: cardNaturalSize)
        return card
    }

    /// A section heading: a quiet uppercase label above its block. Not a cell — it never enters
    /// `cells`, so arrow navigation never lands on it.
    private static func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = Theme.current.chrome.ink(.faint)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: headerHeight).isActive = true
        return label
    }

    private func moveHighlight(_ delta: Int) {
        guard !cells.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), cells.count - 1)
        refreshHighlight()
        cells[highlighted].scrollToVisible(cells[highlighted].bounds)
    }

    /// The highlighted cell reads as the current pick — an accent ring (its own border, which
    /// `IconButton.update()` never touches) plus the active accent fill.
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
        let available = max(120, contentView.bounds.height - Self.windowMargin * 2)
        let height = min(cardNaturalSize.height, available)
        // Widen only when it will actually scroll, so a card that fits keeps even margins.
        let scrolls = height < cardNaturalSize.height
        let size = NSSize(
            width: cardNaturalSize.width + (scrolls ? Self.scrollerGutter : 0), height: height)
        let origin = convert(bounds, to: contentView)
        let x = max(8, min(origin.minX, contentView.bounds.width - size.width - 8))
        // contentView isn't flipped: below the button = a smaller y. Prefer below; flip above if it
        // would run off the bottom, then clamp so the card never draws outside the window.
        let below = origin.minY - size.height - 4
        let above = origin.maxY + 4
        let maxY = max(8, contentView.bounds.height - size.height - 8)
        var y = below
        if y < 8 { y = above }
        y = max(8, min(y, maxY))
        card.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
