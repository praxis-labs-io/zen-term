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
    private let symbols: [String]
    private var cells: [IconButton] = []
    private var highlighted = 0

    private static let columns = 8
    /// The grid's width, exposed so `IconCatalogTests` can pin the roster to the real layout
    /// constant rather than a copy of it — the two drifting is what leaves a ragged last row.
    static var columnsForTesting: Int { columns }
    private static let cellSize: CGFloat = 34
    private static let cellSpacing: CGFloat = 4
    private static let maxGridHeight: CGFloat = 320
    private static var restFill: NSColor { Theme.current.chrome.ink(alpha: 0.06) }
    private static var focusFill: NSColor { PaletteOverlay.selectionBackground }

    /// Test hooks: open the grid and drive it without a live event loop.
    func openForTesting() { openPopover() }
    func moveHighlightForTesting(_ delta: Int) { moveHighlight(delta) }
    func commitHighlightForTesting() { commitHighlight() }

    init(selected: String) {
        let initial = selected.isEmpty ? IconCatalog.defaultSymbol : selected
        // Keep a custom (non-catalog) icon selectable so editing a float never drops it.
        symbols = IconCatalog.all.contains(initial) ? IconCatalog.all : [initial] + IconCatalog.all
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
        chevron.contentTintColor = Theme.current.chrome.ink(alpha: 0.5)
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
        layer?.borderColor = (active ? chrome.accent.nsColor : chrome.ink(alpha: 0.10)).cgColor
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

    override func keyDown(with event: NSEvent) {
        if popover != nil {
            switch KeyboardFocus.key(for: event) {
            case .left: moveHighlight(-1)
            case .right: moveHighlight(1)
            case .up: moveHighlight(-Self.columns)
            case .down: moveHighlight(Self.columns)
            case .activate: commitHighlight()
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
        highlighted = max(0, symbols.firstIndex(of: selected) ?? 0)
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

        var row: NSStackView?
        for (index, symbol) in symbols.enumerated() {
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
            // IconButton now owns hover labeling via its branded tooltip (the accessibility label
            // above is the glyph name), so no native cell.toolTip is needed.
            row?.addArrangedSubview(cell)
            cells.append(cell)
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
        let rows = (symbols.count + Self.columns - 1) / Self.columns
        let gridWidth = CGFloat(Self.columns) * Self.cellSize + CGFloat(Self.columns - 1) * Self.cellSpacing
        let gridHeight = CGFloat(rows) * Self.cellSize + CGFloat(max(rows - 1, 0)) * Self.cellSpacing
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
        let cardHeight = min(gridHeight + inset * 2, Self.maxGridHeight)
        card.frame = NSRect(x: 0, y: 0, width: gridWidth + inset * 2, height: cardHeight)
        return card
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
        commit(symbols[highlighted])
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
        let size = card.frame.size
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
